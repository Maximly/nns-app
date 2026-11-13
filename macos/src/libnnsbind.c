/*++

Abstract:

    Experimental macOS nns-app socket source binding interposer.

    Hooks calls to libc connect() for IPv4 TCP sockets, binding an unbound socket
    to NNS_BIND_IPV4 before calling the real connect().
    Not a security boundary: Network.framework/connectx/UDP/SIP-protected apps,
    existing sockets, and direct syscalls can bypass this.
    getaddrinfo() queries the specified IPv4 DNS server through utun without
    touching the macOS system DNS configuration. A-only DNS, no TCP fallback.

Revision History:

    10/11/2026 - Maxim Lyadvinsky - Created

--*/
#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <sys/select.h>
#include <time.h>
#include <netinet/in.h>
#include <net/if.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include "nns_net.h"

#ifndef DYLD_INTERPOSE
/**
 * DYLD_INTERPOSE() - register a dyld function interpose pair
 *  @replacement: interposed implementation
 *  @replacee: original libc symbol to replace
 *
 * Places a {replacement, replacee} record in __DATA,__interpose so dyld
 * redirects calls to @replacee toward @replacement in this process.
 */
#define DYLD_INTERPOSE(replacement, replacee)   \
    __attribute__((used)) static struct {       \
        const void* replacement;                \
        const void* replacee;                   \
    } _nns_interpose_##replacee __attribute__((section("__DATA,__interpose"))) = { \
        (const void*)(uintptr_t)&replacement,   \
        (const void*)(uintptr_t)&replacee       \
    }
#endif

#define NNS_LOG_BUF 300

/* DNS wire format (RFC 1035) */
enum nns_dns_wire {
    NNS_DNS_NAME_MAX = 253,
    NNS_DNS_LABEL_MAX = 63,
    NNS_DNS_SKIP_MAX = 128,
    NNS_DNS_HEADER = 12,
    NNS_DNS_QTAIL = 4,           /* QTYPE + QCLASS */
    NNS_DNS_RR_FIXED = 10,       /* TYPE + CLASS + TTL + RDLEN */
    NNS_DNS_REQ_CAP = 512,
    NNS_DNS_RESP_CAP = 2048,
    NNS_DNS_PORT = 53,
    NNS_DNS_TIMEOUT_SEC = 2,
    NNS_DNS_TRIES = 2,
    NNS_DNS_TYPE_A = 1,
    NNS_DNS_CLASS_IN = 1,
    NNS_DNS_A_RDLEN = 4,
    NNS_DNS_FLAG_RD = 0x01,      /* recursion desired (byte 2) */
    NNS_DNS_FLAG_TC = 0x02,      /* truncated (byte 2) */
    NNS_DNS_FLAG_QR = 0x80,      /* response (byte 2) */
    NNS_DNS_RCODE_MASK = 0x0f,
    NNS_DNS_COMPRESS_MASK = 0xc0,

    /* Header field offsets */
    NNS_DNS_OFF_ID = 0,
    NNS_DNS_OFF_FLAGS = 2,
    NNS_DNS_OFF_QDCOUNT = 4,
    NNS_DNS_OFF_ANCOUNT = 6,

    /* RR fixed-part offsets (after the owner name) */
    NNS_DNS_RR_OFF_TYPE = 0,
    NNS_DNS_RR_OFF_CLASS = 2,
    NNS_DNS_RR_OFF_RDLEN = 8
};


/**
 * nns_dns_get_u16() - load a big-endian u16 from a DNS buffer
 *  @p: pointer to two wire bytes
 *
 * Return: host-order value
 */
static inline uint16_t nns_dns_get_u16(const uint8_t *p)
{
    return ntohs(*(uint16_t*)p);
}


/**
 * nns_dns_put_u16() - store a u16 into a DNS buffer in network order
 *  @p: destination for two wire bytes
 *  @host: host-order value
 */
static void nns_dns_put_u16(unsigned char *p, uint16_t host)
{
    uint16_t v = htons(host);
    memcpy(p, &v, sizeof(v));
}


/**
 * nns_log_enabled() - whether NNS_BIND_DEBUG requests stderr tracing
 *
 * Return: non-zero when debug logging should be emitted
 */
static int nns_log_enabled(void)
{
    const char* s = getenv("NNS_BIND_DEBUG");
    return s && strcmp(s, "0") != 0 && *s;
}


/**
 * nns_log() - write one debug line to stderr without clobbering errno
 *  @event: short event tag
 *  @detail: optional detail string, or NULL
 */
static void nns_log(const char *event, const char *detail)
{
    if (!nns_log_enabled())
        return;

    char buffer[NNS_LOG_BUF];
    int saved = errno;
    int len = snprintf(buffer, sizeof(buffer),
        "[libnnsbind pid=%i] %s%s%s\n",
        getpid(), event,
        detail ? ": " : "",
        detail ? detail : "");

    if (len > 0) {
        size_t n = len;
        if (n >= sizeof(buffer))
            n = sizeof(buffer) - 1;
        write(STDERR_FILENO, buffer, n);
    }

    errno = saved;
}


/**
 * nns_init() - dylib constructor: mark interposer as loaded
 *
 * Sets NNS_BIND_HOOK_READY for the launcher probe. This is not a reliable
 * security guarantee that every subsequent socket call will be intercepted.
 */
__attribute__((constructor)) static void nns_init(void)
{
    /* Probe flag only; not a security guarantee. */
    setenv("NNS_BIND_HOOK_READY", "1", 1);
    nns_log("loaded", "IPv4 TCP connect() interposer");
}


/**
 * nns_connect() - interpose connect(2); bind IPv4 TCP to the VPN source
 *  @fd: socket file descriptor
 *  @address: peer address
 *  @address_len: size of @address
 *
 * For unbound IPv4 TCP sockets to non-local destinations, bind the VPN
 * source address and pin the interface with IP_BOUND_IF, then call the
 * real connect(). Local/multicast/link-local and non-TCP traffic pass
 * through. External IPv6 is rejected (EAFNOSUPPORT).
 *
 * Return: same as connect(2), or NNS_ERR with errno set on local failure
 */
static int nns_connect(int fd, const struct sockaddr *address, socklen_t address_len)
{
    if (!address)
        return connect(fd, address, address_len);

    /* No IPv6 tunneling yet: allow loopback only; reject other IPv6 peers
     * so the managed process cannot leak via the global IPv6 stack. */
    if (address->sa_family == AF_INET6 && address_len >= sizeof(struct sockaddr_in6)) {
        const struct sockaddr_in6* d6 = (void*)address;
        if (IN6_IS_ADDR_LOOPBACK(&d6->sin6_addr))
            return connect(fd, address, address_len);
        errno = EAFNOSUPPORT;
        return NNS_ERR;
    }

    if (address_len < sizeof(struct sockaddr_in) || address->sa_family != AF_INET)
        return connect(fd, address, address_len);

    const struct sockaddr_in* dst = (void*)address;
    uint32_t d = ntohl(dst->sin_addr.s_addr);

    /* localhost, 0/8, multicast, and link-local stay on the host stack */
    if (nns_ipv4_is_host_local(d))
        return connect(fd, address, address_len);

    int socket_type = 0;
    socklen_t socket_type_len = sizeof(socket_type);
    if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &socket_type, &socket_type_len) != 0 ||
        socket_type != SOCK_STREAM) {
        return connect(fd, address, address_len);
    }

    const char* source_ip = getenv("NNS_BIND_IPV4");
    if (!source_ip || !*source_ip) {
        nns_log("not-bound", "NNS_BIND_IPV4 missing");
        return connect(fd, address, address_len);
    }

    struct sockaddr_in src = {};
    src.sin_family = AF_INET;
    src.sin_len = sizeof(src);
    src.sin_port = htons(0);
    if (inet_pton(AF_INET, source_ip, &src.sin_addr) != 1) {
        errno = EINVAL;
        nns_log("bad-source-ip", source_ip);
        return NNS_ERR;
    }

    struct sockaddr_in existing = {};
    socklen_t existing_len = sizeof(existing);
    if (getsockname(fd, (void*)&existing, &existing_len) < 0) {
        nns_log("getsockname-failed", NULL);
        return NNS_ERR;
    }

    /* Reject an application-chosen source outside the VPN. A prior bind to
     * INADDR_ANY may keep its ephemeral port when we bind the VPN address. */
    if (existing.sin_addr.s_addr != INADDR_ANY &&
        existing.sin_addr.s_addr != src.sin_addr.s_addr) {
        errno = EADDRNOTAVAIL;
        nns_log("wrong-source", "socket bound outside selected VPN");
        return NNS_ERR;
    }

    /* IP_BOUND_IF forces egress via an interface that only has an
     * interface-scoped default route (no system-wide VPN routes). */
    const char* interface = getenv("NNS_BIND_IFACE");
    if (!interface || !*interface) {
        errno = EINVAL;
        nns_log("no-interface", "NNS_BIND_IFACE missing");
        return NNS_ERR;
    }

    uint ifindex = if_nametoindex(interface);
    if (!ifindex) {
        errno = ENODEV;
        nns_log("invalid-interface", interface);
        return NNS_ERR;
    }

    if (setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &ifindex, sizeof(ifindex)) != 0) {
        nns_log("IP_BOUND_IF-failed", interface);
        return NNS_ERR;
    }

    nns_log("if-bound", interface);

    if (existing.sin_port == 0 && existing.sin_addr.s_addr == INADDR_ANY) {
        if (bind(fd, (const struct sockaddr *)(const void *)&src, sizeof(src)) < 0) {
            nns_log("bind-failed", source_ip);
            return NNS_ERR;
        }
        nns_log("bound", source_ip);
    } else {
        nns_log("preserved-binding", source_ip);
    }

    return connect(fd, address, address_len);
}
DYLD_INTERPOSE(nns_connect, connect);


/**
 * Minimal self-contained IPv4 DNS client for private VPN names.
 *
 * Queries only go through the selected utun. There is no host DNS fallback
 * when NNS_DNS_IPV4 is absent or the query fails. Numeric and localhost
 * names keep OS behavior. Network.framework DNS is not covered.
 *
 * nns_dns_encode() - encode a dotted name into DNS wire labels
 *  @name: hostname (ASCII labels separated by '.')
 *  @out: output buffer for the encoded name
 *  @cap: capacity of @out in bytes
 *
 * Return: encoded length including the root zero, or NNS_ERR
 */
static int nns_dns_encode(const char* name, uint8_t* out, size_t cap)
{
    const char* p = name;
    size_t n = 0;

    if (!name || !*name || strlen(name) > NNS_DNS_NAME_MAX)
        return NNS_ERR;

    while (*p) {
        const char* dot = strchr(p, '.');
        size_t len = dot ? dot - p : strlen(p);

        /* Accept a single trailing dot (FQDN form). */
        if (len == 0 && dot && dot[1] == 0)
            break;

        if (len == 0 || len > NNS_DNS_LABEL_MAX || n + len + 2 > cap)
            return NNS_ERR;

        out[n++] = len;
        memcpy(out + n, p, len);
        n += len;

        if (!dot)
            break;

        p = dot + 1;
    }

    if (n >= cap)
        return NNS_ERR;

    out[n++] = 0;

    return n;
}


/**
 * nns_dns_skip() - advance past one DNS name in a message
 *  @buf: DNS message
 *  @sz: message length
 *  @pos: in/out byte offset of the name
 *
 * Handles label sequences and one-level compression pointers.
 *
 * Return: NNS_OK after advancing *@pos, or NNS_ERR on truncate/loop
 */
static int nns_dns_skip(const unsigned char* buf, size_t sz, size_t* pos)
{
    size_t p = *pos;

    for (int steps = 0; steps < NNS_DNS_SKIP_MAX; steps++) {
        if (p >= sz)
            return NNS_ERR;

        uint n = buf[p++];
        if (n == 0) {
            *pos = p;
            return NNS_OK;
        }

        /* Compression pointer: 11xxxxxx xxxxxxxx — skip both bytes. */
        if ((n & NNS_DNS_COMPRESS_MASK) == NNS_DNS_COMPRESS_MASK) {
            if (p >= sz)
                return NNS_ERR;
            *pos = p + 1;
            return NNS_OK;
        }

        if (n > NNS_DNS_LABEL_MAX || p + n > sz)
            return NNS_ERR;

        p += n;
    }

    return NNS_ERR;
}


/**
 * nns_dns_finish() - close the DNS UDP socket and log the outcome
 *  @fd: socket to close
 *  @hostname: name used for logging
 *  @err: NNS_OK or NNS_ERR
 *
 * Return: @err
 */
static inline int nns_dns_finish(int fd, const char* hostname, int err)
{
    close(fd);
    if (err == NNS_OK)
        nns_log("dns-resolved", hostname);
    else
        nns_log("dns-failed", hostname);
    return err;
}


/**
 * nns_dns_lookup() - resolve @hostname to one IPv4 address via NNS_DNS_IPV4
 *  @hostname: name to query (A / IN)
 *  @out: filled with the first A record on success
 *
 * Builds a UDP query sourced from NNS_BIND_IPV4 and pinned to NNS_BIND_IFACE.
 * No recursive fallback to the system resolver.
 *
 * Return: NNS_OK on success, NNS_ERR otherwise
 */
static int nns_dns_lookup(const char *hostname, struct in_addr *out)
{
    const char* dns = getenv("NNS_DNS_IPV4");
    const char* ifname = getenv("NNS_BIND_IFACE");
    const char* source = getenv("NNS_BIND_IPV4");
    struct sockaddr_in server = {}, src = {};

    if (!dns || !*dns || !ifname || !*ifname || !source || !*source) {
        nns_log("dns-unavailable", "private DNS server not configured; no host fallback");
        return NNS_ERR;
    }

    if (inet_pton(AF_INET, dns, &server.sin_addr) != 1 ||
        inet_pton(AF_INET, source, &src.sin_addr) != 1) {
        return NNS_ERR;
    }

    uint idx = if_nametoindex(ifname);
    if (idx == 0)
        return NNS_ERR;

    uint8_t req[NNS_DNS_REQ_CAP] = {};
    uint8_t resp[NNS_DNS_RESP_CAP] = {};
    uint16_t id = (uint16_t)((uint)getpid() ^ (uint)time(NULL));

    /* Header: ID, RD=1, QDCOUNT=1 */
    nns_dns_put_u16(req + NNS_DNS_OFF_ID, id);
    req[NNS_DNS_OFF_FLAGS] = NNS_DNS_FLAG_RD;
    nns_dns_put_u16(req + NNS_DNS_OFF_QDCOUNT, 1);

    int enc = nns_dns_encode(
        hostname, req + NNS_DNS_HEADER,
        sizeof(req) - NNS_DNS_HEADER - NNS_DNS_QTAIL);

    if (enc == NNS_ERR)
        return NNS_ERR;

    size_t len = NNS_DNS_HEADER + enc;
    nns_dns_put_u16(req + len, NNS_DNS_TYPE_A);
    len += sizeof(uint16_t);
    nns_dns_put_u16(req + len, NNS_DNS_CLASS_IN);
    len += sizeof(uint16_t);

    int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (fd < 0)
        return NNS_ERR;

    if (setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &idx, sizeof(idx)) != 0)
        return nns_dns_finish(fd, hostname, NNS_ERR);

    src.sin_family = AF_INET;
    src.sin_port = 0;
    src.sin_len = sizeof(src);
    if (bind(fd, (struct sockaddr*)&src, sizeof(src)) != 0)
        return nns_dns_finish(fd, hostname, NNS_ERR);

    server.sin_family = AF_INET;
    server.sin_port = htons(NNS_DNS_PORT);
    server.sin_len = sizeof(server);
    if (connect(fd, (struct sockaddr *)(void *)&server, sizeof(server)) != 0)
        return nns_dns_finish(fd, hostname, NNS_ERR);

    struct timeval timeout = {
        .tv_sec = NNS_DNS_TIMEOUT_SEC,
        .tv_usec = 0
    };
    if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) != 0)
        return nns_dns_finish(fd, hostname, NNS_ERR);

    for (int trial = 0; trial < NNS_DNS_TRIES; trial++) {
        if (send(fd, req, len, 0) != (ssize_t)len)
            break;

        ssize_t got = recv(fd, resp, sizeof(resp), 0);
        if (got < NNS_DNS_HEADER)
            continue;

        size_t sz = (size_t)got;

        /* Matching ID, QR=1, RCODE=0, not truncated */
        if (nns_dns_get_u16(resp + NNS_DNS_OFF_ID) != id ||
            !(resp[NNS_DNS_OFF_FLAGS] & NNS_DNS_FLAG_QR) ||
            (resp[NNS_DNS_OFF_FLAGS + 1] & NNS_DNS_RCODE_MASK) != 0 ||
            (resp[NNS_DNS_OFF_FLAGS] & NNS_DNS_FLAG_TC)) {

            continue;
        }

        uint16_t qd = nns_dns_get_u16(resp + NNS_DNS_OFF_QDCOUNT);
        uint16_t an = nns_dns_get_u16(resp + NNS_DNS_OFF_ANCOUNT);
        size_t p = NNS_DNS_HEADER;

        /* Skip question section */
        for (int i = 0; i < qd; i++) {
            if (nns_dns_skip(resp, sz, &p) != NNS_OK ||
                p + NNS_DNS_QTAIL > sz) {
                return nns_dns_finish(fd, hostname, NNS_ERR);
            }

            p += NNS_DNS_QTAIL;
        }

        /* First matching A/IN answer wins */
        for (int i = 0; i < an; i++) {
            if (nns_dns_skip(resp, sz, &p) != NNS_OK ||
                p + NNS_DNS_RR_FIXED > sz) {
                return nns_dns_finish(fd, hostname, NNS_ERR);
            }

            uint16_t type = nns_dns_get_u16(resp + p + NNS_DNS_RR_OFF_TYPE);
            uint16_t cls = nns_dns_get_u16(resp + p + NNS_DNS_RR_OFF_CLASS);
            uint16_t rdlen = nns_dns_get_u16(resp + p + NNS_DNS_RR_OFF_RDLEN);
            p += NNS_DNS_RR_FIXED;

            if (p + rdlen > sz)
                return nns_dns_finish(fd, hostname, NNS_ERR);

            if (type == NNS_DNS_TYPE_A && cls == NNS_DNS_CLASS_IN &&
                rdlen == NNS_DNS_A_RDLEN) {
                memcpy(&out->s_addr, resp + p, NNS_DNS_A_RDLEN);
                return nns_dns_finish(fd, hostname, NNS_OK);
            }

            p += rdlen;
        }
    }

    return nns_dns_finish(fd, hostname, NNS_ERR);
}


/**
 * nns_getaddrinfo() - interpose getaddrinfo(3); VPN DNS for IPv4 names
 * @node: hostname or numeric address
 * @service: service name or port string
 * @hints: optional resolution hints
 * @res: result list on success
 *
 * Numeric hosts, localhost*, and AI_NUMERICHOST keep the system resolver.
 * Other IPv4/UNSPEC queries use nns_dns_lookup(), then re-enter getaddrinfo
 * with AI_NUMERICHOST. Non-IPv4 families return EAI_NONAME.
 *
 * Return: 0 on success, or a getaddrinfo(3) EAI_* code
 */
static int nns_getaddrinfo(
    const char *node,
    const char *service,
    const struct addrinfo *hints,
    struct addrinfo **res)
{
    if (!node || !*node || (hints && (hints->ai_flags & AI_NUMERICHOST)))
        return getaddrinfo(node, service, hints, res);

    struct in_addr numeric4;
    struct in6_addr numeric6;
    static const char localhost_suffix[] = ".localhost";
    size_t node_len = strlen(node);
    size_t suffix_len = sizeof(localhost_suffix) - 1;

    /* Leave numeric and localhost names to the OS. */
    if (inet_pton(AF_INET, node, &numeric4) == 1 ||
        inet_pton(AF_INET6, node, &numeric6) == 1 ||
        strcmp(node, "localhost") == 0 || strcmp(node, "localhost.") == 0 ||
            (node_len > suffix_len &&
            strcmp(node + node_len - suffix_len, localhost_suffix) == 0)) {

        return getaddrinfo(node, service, hints, res);
    }

    if (hints && hints->ai_family != AF_INET && hints->ai_family != AF_UNSPEC)
        return EAI_NONAME;

    struct in_addr resolved;
    if (nns_dns_lookup(node, &resolved) != NNS_OK)
        return EAI_AGAIN;

    char address[INET_ADDRSTRLEN];
    if (!inet_ntop(AF_INET, &resolved, address, sizeof(address)))
        return EAI_FAIL;

    struct addrinfo h = {};
    if (hints)
        h = *hints;
    h.ai_family = AF_INET;
    h.ai_flags |= AI_NUMERICHOST;
    return getaddrinfo(address, service, &h, res);
}

DYLD_INTERPOSE(nns_getaddrinfo, getaddrinfo);
