/*++

Abstract:

    Experimental launcher: insert libnnsbind.dylib for an unrestricted macOS
    executable, and add native bind options for SIP-protected network tools.

Revision History:

    10/11/2026 - Maxim Lyadvinsky - Created

--*/
#include <arpa/inet.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include "nns_net.h"

#ifndef ARRAY_SIZE
#define ARRAY_SIZE(a) ((int)(sizeof(a) / sizeof(a[0])))
#endif /* ARRAY_SIZE */

/* Exit status for usage / option errors (sysexits-style EX_USAGE). */
enum nns_run_exit {
    NNS_RUN_EXIT_USAGE = 2,
    NNS_RUN_EXIT_EXEC = 127
};

/* Fixed buffer sizes used while rewriting argv / parsing URLs. */
enum nns_run_buf {
    NNS_RUN_HOST_BUF = 256,
    NNS_RUN_PATH_ENTRY_BUF = 512,
    NNS_RUN_RESOLVE_BUF = 1024,
    NNS_RUN_BIND_STORAGE = 80,
    NNS_RUN_EXTRA_ARGS = 2
};

/* strlen() of fixed option / path prefixes (exclude the trailing NUL). */
enum nns_run_prefix_len {
    NNS_RUN_LEN_SSH_O = sizeof("-o") - 1,
    NNS_RUN_LEN_BIND_ADDRESS = sizeof("BindAddress=") - 1,
    NNS_RUN_LEN_BIND_INTERFACE = sizeof("BindInterface=") - 1,
    NNS_RUN_LEN_LOCALHOST_DOT = sizeof(".localhost") - 1,
    NNS_RUN_LEN_LOCALHOST_DOT_DOT = sizeof(".localhost.") - 1,
    NNS_RUN_LEN_URL_SCHEME = sizeof("://") - 1,
    NNS_RUN_LEN_HTTP = sizeof("http") - 1,
    NNS_RUN_LEN_BIN = sizeof("/bin/") - 1,
    NNS_RUN_LEN_SBIN = sizeof("/sbin/") - 1,
    NNS_RUN_LEN_USR_BIN = sizeof("/usr/bin/") - 1,
    NNS_RUN_LEN_USR_SBIN = sizeof("/usr/sbin/") - 1,
    NNS_RUN_LEN_SYSTEM = sizeof("/System/") - 1
};

/* insert_after sentinel: splice bind args before all user argv entries. */
enum nns_run_insert {
    NNS_RUN_INSERT_BEFORE_ALL = -1
};


static void usage(const char* name)
 {
    fprintf(stderr,
        "Usage: %s --vpn-ip IPv4 --vpn-if utunN --lib /absolute/path/libnnsbind.dylib [--debug] -- command [args...]\n"
        "Adds native bind options for ping, nc, ssh/scp/sftp, curl, dig, traceroute,\n"
        "wget, rsync and openssl s_client. Other SIP/hardened apps can ignore injection;\n"
        "this is not a sandbox. Set NNS_BIND_QUIET=1 to hide compatibility warnings.\n",
        name);
}


/**
 * nns_basename() - final path component of an executable name
 *  @path: command path from argv
 *
 * Return: pointer inside @path, never NULL
 */
static inline const char* nns_basename(const char* path)
{
    const char* slash = strrchr(path, '/');
    return slash ? slash + 1 : path;
}


/**
 * nns_has_short_arg() - lookup a short option, including attached values
 *  @args: child arguments (argv[0] excluded)
 *  @count: number of arguments
 *  @option: option letter, without the leading dash
 *
 * A user-supplied "-b utunN" and "-butunN" both suppress our default.
 *
 * Return: true when the option appears
 */
static bool nns_has_short_arg(const char* const* args, int count, char option)
{
    for (int i = 0; i < count; i++) {
        if (args[i][0] == '-' && args[i][1] == option)
            return true;
    }
    return false;
}


/**
 * nns_is_local_host() - whether a destination stays on the host stack
 *  @host: hostname or numeric address, without brackets
 *
 * Mirrors the interposer's local-destination policy: loopback, 0/8,
 * multicast, IPv4 link-local and IPv6 loopback/link-local/multicast are not
 * sent through the tunnel.
 *
 * Return: true for a local destination
 */
static bool nns_is_local_host(const char* host)
{
    if (!host || !*host)
        return false;

    struct in_addr v4;
    if (inet_pton(AF_INET, host, &v4) == 1)
        return nns_ipv4_is_host_local(ntohl(v4.s_addr));

    struct in6_addr v6;
    if (inet_pton(AF_INET6, host, &v6) == 1) {
        return IN6_IS_ADDR_LOOPBACK(&v6) || IN6_IS_ADDR_LINKLOCAL(&v6) ||
            IN6_IS_ADDR_MULTICAST(&v6);
    }

    size_t len = strlen(host);
    if (!strcasecmp(host, "localhost") || !strcasecmp(host, "localhost."))
        return true;

    if (len >= NNS_RUN_LEN_LOCALHOST_DOT &&
        !strcasecmp(host + len - NNS_RUN_LEN_LOCALHOST_DOT, ".localhost"))
        return true;

    if (len >= NNS_RUN_LEN_LOCALHOST_DOT_DOT &&
        !strcasecmp(host + len - NNS_RUN_LEN_LOCALHOST_DOT_DOT, ".localhost."))
        return true;

    return false;
}


/**
 * nns_quiet() - whether compatibility warnings are suppressed
 *
 * Return: true when NNS_BIND_QUIET is set to a non-"0" value
 */
static bool nns_quiet(void)
{
    const char* value = getenv("NNS_BIND_QUIET");
    return value && strcmp(value, "0") != 0 && *value;
}


/**
 * nns_path_is_apple_prefix() - path under an Apple SIP platform prefix
 *  @path: absolute or relative executable path
 *
 * Return: true for /bin /sbin /usr/bin /usr/sbin /System
 */
static bool nns_path_is_apple_prefix(const char* path)
{
    if (!path || *path != '/')
        return false;

    static const char* paths[] = {
        "/bin/",
        "/sbin/",
        "/usr/bin/",
        "/usr/sbin/",
        "/System/"
    };

    for (int i = 0; i < ARRAY_SIZE(paths); ++i) {
        if (strncmp(path, paths[i], strlen(paths[i])) == 0)
            return true;
    }
    return false;
}


/**
 * nns_resolve_command() - best-effort PATH lookup for a bare command name
 *  @program: argv[0]
 *  @out: receives an absolute path when found
 *  @out_size: capacity of @out
 *
 * Return: 0 when @out is filled, -1 when unresolved
 */
static int nns_resolve_command(const char* program, char* out, size_t out_size)
{
    if (!program || !*program || !out || out_size < 2)
        return NNS_ERR;

    if (strchr(program, '/')) {
        if (snprintf(out, out_size, "%s", program) >= (int)out_size)
            return NNS_ERR;
        return access(out, X_OK) == 0 ? NNS_OK : NNS_ERR;
    }

    const char* path = getenv("PATH");
    if (!path || !*path)
        path = "/usr/bin:/bin:/usr/sbin:/sbin";

    char entry[512];
    const char* cursor = path;
    while (*cursor) {
        const char* sep = strchr(cursor, ':');
        size_t len = sep ? (size_t)(sep - cursor) : strlen(cursor);
        if (len > 0 && len < sizeof(entry)) {
            memcpy(entry, cursor, len);
            entry[len] = '\0';
            if (snprintf(out, out_size, "%s/%s", entry, program) < (int)out_size &&
                access(out, X_OK) == 0) {
                return NNS_OK;
            }
        }
        if (!sep)
            break;
        cursor = sep + 1;
    }

    return NNS_ERR;
}


/**
 * nns_has_long_opt() - whether argv contains a GNU-style long option
 *  @args: child arguments (argv[0] excluded)
 *  @count: number of arguments
 *  @option: exact form ("--interface") or prefix ("--bind-address=")
 *
 * Return: true when present as exact argv or as prefix=
 */
static bool nns_has_long_opt(
    const char* const* args,
    int count,
    const char* option)
{
    size_t option_len = strlen(option);
    bool prefix = option_len > 0 && option[option_len - 1] == '=';

    for (int i = 0; i < count; i++) {
        if (prefix) {
            if (strncmp(args[i], option, option_len) == 0)
                return true;
        } else if (strcmp(args[i], option) == 0) {
            return true;
        }
    }
    return false;
}


/* Row action when the basename matches. */
enum nns_bind_action {
    NNS_BIND_ACTION_INJECT = 0,
    NNS_BIND_ACTION_REJECT_IPV6,
    NNS_BIND_ACTION_WARN_GIT
};

/* How the inserted value is produced. */
enum nns_bind_valsrc {
    NNS_BIND_VAL_IFACE = 0,
    NNS_BIND_VAL_IP,
    NNS_BIND_VAL_FMT_IP          /* sprintf(value_fmt, ip) into storage */
};

/* How to locate destination operands in argv. */
enum nns_bind_scan {
    NNS_BIND_SCAN_NONE = 0,             /* no destination check */
    NNS_BIND_SCAN_FIRST,                /* first non-option (ssh/nc); respects -- */
    NNS_BIND_SCAN_LAST_WALK,            /* last non-option with opt-value skipping */
    NNS_BIND_SCAN_LAST_PLAIN,           /* last argv entry not starting with '-' */
    NNS_BIND_SCAN_ANY,                  /* every non-option-looking argv entry */
    NNS_BIND_SCAN_URLS                  /* URL-like argv entries, else last plain */
};

/* How to interpret a destination string for the local-host policy. */
enum nns_bind_host_form {
    NNS_BIND_HOST_PLAIN = 0,
    NNS_BIND_HOST_AT,                   /* optional leading @ (dig @server) */
    NNS_BIND_HOST_SCP,                  /* [user@]host:path */
    NNS_BIND_HOST_URL                   /* scheme://[user@]host/... or host:port */
};

/* When to skip injection based on local destinations. */
enum nns_bind_local {
    NNS_BIND_LOCAL_IGNORE = 0,          /* never skip for locality (rsync/openssl) */
    NNS_BIND_LOCAL_IF_DEST,             /* skip when the scanned dest is local */
    NNS_BIND_LOCAL_IF_ANY,              /* skip when any scanned operand is local */
    NNS_BIND_LOCAL_IF_ALL_URLS          /* skip when every URL operand is local */
};


/**
 * struct nns_bind_app - Self-contained SIP/native-bind recipe.
 */
struct nns_bind_app {
    const char* name;                   /* argv0 basename */
    enum nns_bind_action action;        /* inject / reject IPv6 / git warning */
    const char* flag;                   /* first inserted argv piece, or NULL for value-only */
    enum nns_bind_valsrc valsrc;        /* iface, ip, or formatted ip */
    const char* value_fmt;              /* printf format for NNS_BIND_VAL_FMT_IP (ip only) */
    const char* suppress_short;         /* short option letters that disable injection */
    const char* suppress_longs;         /* NUL-separated long options (double-NUL terminated) */
    const char* opts_take_arg;          /* short options that consume the next argv during scans */
    enum nns_bind_scan scan;            /* destination discovery mode */
    enum nns_bind_host_form host_form;  /* how to parse destination strings */
    enum nns_bind_local local;          /* locality skip policy */
    bool suppress_before_dest;          /* limit short/long/ssh-o suppress to argv before dest */
    bool ssh_o_bind;                    /* also treat -o BindAddress=/BindInterface= as suppress */
    const char* require_arg;            /* exact argv that must appear (e.g. s_client) */
    bool insert_after_require;          /* splice bind args after @require_arg */
};

/* Embedded NULs: each long option, then an extra NUL terminator. */
#define NNS_LONGS1(a) a "\0"
#define NNS_LONGS2(a, b) a "\0" b "\0"

static const struct nns_bind_app nns_bind_apps[] = {
    {
        .name = "ping6",
        .action = NNS_BIND_ACTION_REJECT_IPV6,
    },
    {
        .name = "traceroute6",
        .action = NNS_BIND_ACTION_REJECT_IPV6,
    },
    {
        .name = "git",
        .action = NNS_BIND_ACTION_WARN_GIT,
    },
    {
        .name = "ping",
        .flag = "-b",
        .valsrc = NNS_BIND_VAL_IFACE,
        .suppress_short = "bS",
        .opts_take_arg = "bcGghikKlMmPpSsTtWzI",
        .scan = NNS_BIND_SCAN_LAST_WALK,
        .host_form = NNS_BIND_HOST_PLAIN,
        .local = NNS_BIND_LOCAL_IF_DEST,
    },
    {
        .name = "nc",
        .flag = "-b",
        .valsrc = NNS_BIND_VAL_IFACE,
        .suppress_short = "bslU",
        .opts_take_arg = "bGHiKpswXx",
        .scan = NNS_BIND_SCAN_FIRST,
        .host_form = NNS_BIND_HOST_PLAIN,
        .local = NNS_BIND_LOCAL_IF_DEST,
    },
    {
        .name = "ssh",
        .flag = "-b",
        .valsrc = NNS_BIND_VAL_IP,
        .suppress_short = "b",
        .opts_take_arg = "BbcDEeFIiJlLmoOpPQRSWwY",
        .scan = NNS_BIND_SCAN_FIRST,
        .host_form = NNS_BIND_HOST_PLAIN,
        .local = NNS_BIND_LOCAL_IF_DEST,
        .suppress_before_dest = true,
        .ssh_o_bind = true,
    },
    {
        .name = "scp",
        .flag = "-o",
        .valsrc = NNS_BIND_VAL_FMT_IP,
        .value_fmt = "BindAddress=%s",
        .scan = NNS_BIND_SCAN_LAST_PLAIN,
        .host_form = NNS_BIND_HOST_SCP,
        .local = NNS_BIND_LOCAL_IF_DEST,
        .ssh_o_bind = true,
    },
    {
        .name = "sftp",
        .flag = "-o",
        .valsrc = NNS_BIND_VAL_FMT_IP,
        .value_fmt = "BindAddress=%s",
        .scan = NNS_BIND_SCAN_LAST_PLAIN,
        .host_form = NNS_BIND_HOST_SCP,
        .local = NNS_BIND_LOCAL_IF_DEST,
        .ssh_o_bind = true,
    },
    {
        .name = "curl",
        .flag = "--interface",
        .valsrc = NNS_BIND_VAL_IFACE,
        .suppress_longs = NNS_LONGS2("--interface", "--interface="),
        .scan = NNS_BIND_SCAN_URLS,
        .host_form = NNS_BIND_HOST_URL,
        .local = NNS_BIND_LOCAL_IF_ALL_URLS,
    },
    {
        .name = "wget",
        .valsrc = NNS_BIND_VAL_FMT_IP,
        .value_fmt = "--bind-address=%s",
        .suppress_longs = NNS_LONGS2("--bind-address", "--bind-address="),
        .scan = NNS_BIND_SCAN_URLS,
        .host_form = NNS_BIND_HOST_URL,
        .local = NNS_BIND_LOCAL_IF_ALL_URLS,
    },
    {
        .name = "rsync",
        .valsrc = NNS_BIND_VAL_FMT_IP,
        .value_fmt = "--address=%s",
        .suppress_longs = NNS_LONGS2("--address", "--address="),
        .scan = NNS_BIND_SCAN_NONE,
        .local = NNS_BIND_LOCAL_IGNORE,
    },
    {
        .name = "openssl",
        .flag = "-bind",
        .valsrc = NNS_BIND_VAL_FMT_IP,
        .value_fmt = "%s:0",
        .suppress_longs = NNS_LONGS1("-bind"),
        .scan = NNS_BIND_SCAN_NONE,
        .local = NNS_BIND_LOCAL_IGNORE,
        .require_arg = "s_client",
        .insert_after_require = true,
    },
    {
        .name = "dig",
        .flag = "-b",
        .valsrc = NNS_BIND_VAL_IP,
        .suppress_short = "b",
        .scan = NNS_BIND_SCAN_ANY,
        .host_form = NNS_BIND_HOST_AT,
        .local = NNS_BIND_LOCAL_IF_ANY,
    },
    {
        .name = "traceroute",
        .flag = "-s",
        .valsrc = NNS_BIND_VAL_IP,
        .suppress_short = "is",
        .scan = NNS_BIND_SCAN_LAST_PLAIN,
        .host_form = NNS_BIND_HOST_PLAIN,
        .local = NNS_BIND_LOCAL_IF_DEST,
    },
};


/**
 * nns_opt_takes_arg() - whether a short option letter consumes the next argv
 *  @opts_take_arg: letters from the recipe, or NULL
 *  @option: short option character
 */
static bool nns_opt_takes_arg(const char* opts_take_arg, char option)
{
    return opts_take_arg && strchr(opts_take_arg, option) != NULL;
}


/**
 * nns_skip_short_opt() - advance index past a short option and its value
 *  @args: argv slice
 *  @count: length
 *  @index: current index (points at the "-…" entry)
 *  @opts_take_arg: letters that take a separate value
 *
 * Return: index of the next argument to inspect
 */
static int nns_skip_short_opt(
    const char* const* args,
    int count,
    int index,
    const char* opts_take_arg)
{
    const char* arg = args[index];
    bool separate = false;

    if (arg[1] == '-' || arg[1] == '\0')
        return index + 1;

    for (const char* p = arg + 1; *p; p++) {
        if (nns_opt_takes_arg(opts_take_arg, *p)) {
            separate = p[1] == '\0';
            break;
        }
    }

    if (separate && index + 1 < count)
        return index + 2;

    return index + 1;
}


/**
 * nns_scan_dest() - find a destination operand per recipe scan mode
 *  @args: child arguments
 *  @count: length
 *  @app: recipe (scan + opts_take_arg)
 *  @out_index: optional index of the returned operand
 *
 * Return: destination string, or NULL
 */
static const char* nns_scan_dest(
    const char* const* args,
    int count,
    const struct nns_bind_app* app,
    int* out_index)
{
    const char* found = NULL;
    int found_at = -1;

    if (out_index)
        *out_index = -1;

    if (app->scan == NNS_BIND_SCAN_NONE ||
        app->scan == NNS_BIND_SCAN_ANY ||
        app->scan == NNS_BIND_SCAN_URLS) {
        return NULL;
    }

    if (app->scan == NNS_BIND_SCAN_LAST_PLAIN) {
        for (int i = count - 1; i >= 0; i--) {
            if (args[i][0] != '-' && args[i][0] != '\0') {
                if (out_index)
                    *out_index = i;
                return args[i];
            }
        }
        return NULL;
    }

    for (int i = 0; i < count; ) {
        const char* arg = args[i];

        if (app->scan == NNS_BIND_SCAN_FIRST && strcmp(arg, "--") == 0) {
            if (i + 1 < count) {
                if (out_index)
                    *out_index = i + 1;
                return args[i + 1];
            }
            return NULL;
        }

        if (arg[0] != '-') {
            if (app->scan == NNS_BIND_SCAN_FIRST) {
                if (out_index)
                    *out_index = i;
                return arg;
            }

            /* LAST_WALK: keep scanning; options may follow the destination. */
            found = arg;
            found_at = i;
            ++i;
            continue;
        }

        i = nns_skip_short_opt(args, count, i, app->opts_take_arg);
    }

    if (found && out_index)
        *out_index = found_at;

    return found;
}


/**
 * nns_host_from_operand() - extract a hostname for local-policy checks
 *  @operand: raw argv text
 *  @form: plain / @server / scp / URL
 *  @host: output buffer
 *  @host_size: capacity of @host
 *
 * Return: true when @host was filled with a candidate name
 */
static bool nns_host_from_operand(
    const char* operand,
    enum nns_bind_host_form form,
    char* host,
    size_t host_size)
{
    if (!operand || !*operand || !host || host_size < 2)
        return false;

    if (form == NNS_BIND_HOST_PLAIN) {
        if (snprintf(host, host_size, "%s", operand) >= (int)host_size)
            return false;
        return true;
    }

    if (form == NNS_BIND_HOST_AT) {
        if (*operand == '@')
            operand++;

        if (snprintf(host, host_size, "%s", operand) >= (int)host_size)
            return false;

        return true;
    }

    if (form == NNS_BIND_HOST_SCP) {
        const char* colon = strrchr(operand, ':');
        const char* start;
        size_t n = 0;

        if (!colon)
            return false;

        start = operand;
        for (const char* p = operand; p < colon; p++) {
            if (*p == '@')
                start = p + 1;
        }

        if (*start == '[') {
            start++;
            while (start < colon && *start != ']' && n + 1 < host_size)
                host[n++] = *start++;
        } else {
            while (start < colon && n + 1 < host_size)
                host[n++] = *start++;
        }

        host[n] = '\0';

        return n > 0;
    }

    /* NNS_BIND_HOST_URL */
    {
        const char* p = strstr(operand, "://");
        const char* end;
        const char* at = NULL;
        size_t n = 0;

        p = p ? p + NNS_RUN_LEN_URL_SCHEME : operand;
        end = p + strlen(p);
        for (const char* q = p; q < end; q++) {
            if (*q == '/' || *q == '?' || *q == '#') {
                end = q;
                break;
            }
        }

        for (const char* q = p; q < end; q++) {
            if (*q == '@')
                at = q;
        }

        if (at)
            p = at + 1;

        if (*p == '[') {
            p++;
            while (p < end && *p != ']' && n + 1 < host_size)
                host[n++] = *p++;
        } else {
            while (p < end && *p != ':' && n + 1 < host_size)
                host[n++] = *p++;
        }

        host[n] = '\0';

        return n > 0;
    }
}


/**
 * nns_operand_is_local() - locality check for one operand under a host form
 */
static bool nns_operand_is_local(
    const char* operand,
    enum nns_bind_host_form form)
{
    char host[NNS_RUN_HOST_BUF];

    if (!nns_host_from_operand(operand, form, host, sizeof(host)))
        return false;

    return nns_is_local_host(host);
}


/**
 * nns_has_ssh_o_bind() - OpenSSH -o BindAddress=/BindInterface= present
 */
static bool nns_has_ssh_o_bind(const char* const* args, int count)
{
    for (int i = 0; i < count; i++) {
        const char* value = NULL;

        if (strcmp(args[i], "-o") == 0 && i + 1 < count) {
            value = args[i + 1];
        } else if (strncmp(args[i], "-o", NNS_RUN_LEN_SSH_O) == 0) {
            value = args[i] + NNS_RUN_LEN_SSH_O;
        }

        if (!value)
            continue;

        if (strncasecmp(value, "BindAddress=", NNS_RUN_LEN_BIND_ADDRESS) == 0 ||
            strncasecmp(value, "BindInterface=", NNS_RUN_LEN_BIND_INTERFACE) == 0) {
            return true;
        }
    }

    return false;
}


/**
 * nns_bind_short_suppressed() - any suppress_short letter present in argv
 */
static bool nns_bind_short_suppressed(
    const char* const* args,
    int count,
    const char* suppress_short)
{
    if (!suppress_short || !*suppress_short)
        return false;

    for (const char* p = suppress_short; *p; p++) {
        if (nns_has_short_arg(args, count, *p))
            return true;
    }

    return false;
}


/**
 * nns_bind_long_suppressed() - any NUL-separated suppress_longs entry present
 */
static bool nns_bind_long_suppressed(
    const char* const* args,
    int count,
    const char* suppress_longs)
{
    if (!suppress_longs)
        return false;

    for (const char* p = suppress_longs; *p; p += strlen(p) + 1) {
        if (nns_has_long_opt(args, count, p))
            return true;
    }

    return false;
}


/**
 * nns_urls_all_local() - curl/wget locality: true => skip tunnel bind
 *
 * If any URL-like operand is remote, return false (do inject). If every
 * URL-like operand is local, return true. With no URL-like operands, fall
 * back to the last plain argv entry parsed as a URL/host.
 */
static bool nns_urls_all_local(const char* const* args, int count)
{
    bool saw_url = false;
    for (int i = 0; i < count; i++) {
        if (strstr(args[i], "://") ||
            !strncasecmp(args[i], "http", NNS_RUN_LEN_HTTP)) {
            saw_url = true;
            if (!nns_operand_is_local(args[i], NNS_BIND_HOST_URL))
                return false;
        }
    }
    if (saw_url)
        return true;

    for (int i = count - 1; i >= 0; i--) {
        if (args[i][0] != '-' && args[i][0] != '\0')
            return nns_operand_is_local(args[i], NNS_BIND_HOST_URL);
    }

    return false;
}


/**
 * nns_any_operand_local() - dig-style: true when any argv host is local
 */
static bool nns_any_operand_local(
    const char* const* args,
    int count,
    enum nns_bind_host_form form)
{
    for (int i = 0; i < count; i++) {
        if (args[i][0] == '-')
            continue;

        if (nns_operand_is_local(args[i], form))
            return true;
    }

    return false;
}


/**
 * nns_bind_gate_ok() - whether a recipe should rewrite argv
 */
static bool nns_bind_gate_ok(
    const struct nns_bind_app* app,
    const char* const* args,
    int count,
    int* insert_after)
{
    int dest_index = -1;
    int option_count = count;
    const char* dest;

    if (app->require_arg) {
        int req = -1;

        for (int i = 0; i < count; i++) {
            if (strcmp(args[i], app->require_arg) == 0) {
                req = i;
                break;
            }
        }

        if (req < 0)
            return false;

        if (app->insert_after_require)
            *insert_after = req;
    }

    dest = nns_scan_dest(args, count, app, &dest_index);
    if (app->suppress_before_dest && dest_index >= 0)
        option_count = dest_index;

    if (nns_bind_short_suppressed(args, option_count, app->suppress_short) ||
        nns_bind_long_suppressed(args, option_count, app->suppress_longs)) {
        return false;
    }

    if (app->ssh_o_bind && nns_has_ssh_o_bind(args, option_count))
        return false;

    switch (app->local) {
        case NNS_BIND_LOCAL_IGNORE:
            return true;
        case NNS_BIND_LOCAL_IF_DEST:
            return dest && !nns_operand_is_local(dest, app->host_form);
        case NNS_BIND_LOCAL_IF_ANY:
            return !nns_any_operand_local(args, count, app->host_form);
        case NNS_BIND_LOCAL_IF_ALL_URLS:
            return !nns_urls_all_local(args, count);
    }

    return false;
}


/**
 * nns_bind_fill_extra() - write inserted argv pieces from recipe value fields
 */
static int nns_bind_fill_extra(
    const struct nns_bind_app* app,
    const char* iface,
    const char* ip,
    const char** extra,
    char* storage,
    size_t storage_size)
{
    const char* value = NULL;

    switch (app->valsrc) {
        case NNS_BIND_VAL_IFACE:
            value = iface;
            break;

        case NNS_BIND_VAL_IP:
            value = ip;
            break;

        case NNS_BIND_VAL_FMT_IP: {
            if (!app->value_fmt)
                return 0;

            int n = snprintf(storage, storage_size, app->value_fmt, ip);
            if (n < 0 || n >= (int)storage_size)
                return 0;

            value = storage;
            break;
        }
    }

    if (!app->flag) {
        extra[0] = value;
        return 1;
    }

    extra[0] = app->flag;
    extra[1] = value;

    return 2;
}


/**
 * nns_add_bind_args() - choose a native bind option from nns_bind_apps[]
 *
 * Return: entries written to @extra (0/1/2), or -1 when the tool is rejected
 */
static int nns_add_bind_args(
    const char* program,
    const char* iface,
    const char* ip,
    const char* const* args,
    int count,
    const char** extra,
    char* storage,
    size_t storage_size,
    int* insert_after)
{
    const char* name = nns_basename(program);

    *insert_after = NNS_RUN_INSERT_BEFORE_ALL;

    for (int i = 0; i < ARRAY_SIZE(nns_bind_apps); i++) {
        const struct nns_bind_app* app = &nns_bind_apps[i];

        if (strcmp(name, app->name) != 0)
            continue;

        switch (app->action) {
            case NNS_BIND_ACTION_REJECT_IPV6:
                fprintf(stderr,
                    "nns-run: %s is not supported: macOS backend routes IPv4 only\n",
                    name);
                return -1;

            case NNS_BIND_ACTION_WARN_GIT:
                if (!nns_quiet()) {
                    fprintf(stderr,
                        "nns-run: warning: git is not auto-bound; use "
                        "'nns-app git-via <app>' for SSH remotes "
                        "(Apple /usr/bin/ssh ignores DYLD injection)\n");
                }
                return 0;

            case NNS_BIND_ACTION_INJECT:
                if (!nns_bind_gate_ok(app, args, count, insert_after))
                    return 0;
                return nns_bind_fill_extra(
                    app, iface, ip, extra, storage, storage_size);
        }

        return 0;
    }

    return 0;
}


int main(int argc, char** argv)
{
    const char* ip = NULL;
    const char* iface = NULL;
    const char* lib = NULL;
    int debug = 0, cmd = -1;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--")) {
            cmd = i + 1;
            break;
        }

        if ((!strcmp(argv[i], "--vpn-ip") ||
            !strcmp(argv[i], "--vpn-if") ||
            !strcmp(argv[i], "--lib")) &&
                i + 1 < argc) {

            if (!strcmp(argv[i], "--vpn-ip")) {
                ip = argv[++i];
            } else if (!strcmp(argv[i], "--vpn-if")) {
                iface = argv[++i];
            } else {
                lib = argv[++i];
            }

        } else if (!strcmp(argv[i], "--debug")) {
            debug = 1;

        } else {
            usage(argv[0]);
            return 2;
        }
    }

    if (!ip || !*ip || !iface || !*iface || !lib ||
        cmd < 0 || cmd >= argc || lib[0] != '/') {
        usage(argv[0]);
        return 2;
    }

    struct in_addr parsed = {};
    if (inet_pton(AF_INET, ip, &parsed) != 1) {
        fprintf(stderr, "Invalid IPv4 source: %s\n", ip);
        return 2;
    }

    if (access(lib, R_OK) != 0) {
        perror("Cannot read dylib");
        return 2;
    }

    if (setenv("NNS_BIND_IPV4", ip, 1) < 0 ||
        setenv("NNS_BIND_IFACE", iface, 1) < 0 ||
        setenv("NNS_BIND_DEBUG", debug ? "1" : "0", 1) < 0 ||
        unsetenv("NNS_BIND_HOOK_READY") < 0 ||
        setenv("DYLD_INSERT_LIBRARIES", lib, 1) < 0) {
        perror("setenv");
        return 2;
    }

    const char* extra[NNS_RUN_EXTRA_ARGS] = { NULL, NULL };
    char bind_storage[NNS_RUN_BIND_STORAGE] = {};
    int insert_after = NNS_RUN_INSERT_BEFORE_ALL;
    int user_count = argc - cmd - 1;
    int extra_count = nns_add_bind_args(
        argv[cmd], iface, ip,
        (const char* const*)(argv + cmd + 1), user_count,
        extra, bind_storage, sizeof(bind_storage), &insert_after);

    if (extra_count < 0)
        return NNS_RUN_EXIT_USAGE;

    if (extra_count == 0) {
        char resolved[NNS_RUN_RESOLVE_BUF];
        const char* name = nns_basename(argv[cmd]);
        if (!nns_quiet() &&
            strcmp(name, "git") != 0 &&
            nns_resolve_command(argv[cmd], resolved, sizeof(resolved)) == NNS_OK &&
            nns_path_is_apple_prefix(resolved)) {
            fprintf(stderr,
                "nns-run: warning: '%s' is an Apple platform binary without a "
                "known bind option; SIP blocks DYLD injection so this process "
                "may use the host network (try a Homebrew build, or a tool "
                "with an explicit bind/interface switch)\n",
                resolved);
        }

        execvp(argv[cmd], argv + cmd);
        fprintf(stderr, "Cannot exec %s: %s\n", argv[cmd], strerror(errno));

        return NNS_RUN_EXIT_EXEC;
    }

    char** child = calloc((size_t)(argc - cmd + extra_count + 1), sizeof(*child));
    if (!child) {
        perror("calloc");
        return NNS_RUN_EXIT_USAGE;
    }

    int n = 0;
    child[n++] = argv[cmd];
    if (insert_after < NNS_RUN_INSERT_BEFORE_ALL ||
        insert_after >= user_count) {
        insert_after = NNS_RUN_INSERT_BEFORE_ALL;
    }

    for (int i = 0; i <= insert_after; i++)
        child[n++] = argv[cmd + 1 + i];

    for (int i = 0; i < extra_count; i++)
        child[n++] = (char*)extra[i];

    for (int i = insert_after + 1; i < user_count; i++)
        child[n++] = argv[cmd + 1 + i];

    child[n] = NULL;

    if (debug) {
        fprintf(stderr, "nns-run: inserting");
        for (int i = 0; i < extra_count; i++)
            fprintf(stderr, " %s", extra[i]);
        fprintf(stderr, " for %s\n", nns_basename(argv[cmd]));
    }

    execvp(child[0], child);
    fprintf(stderr, "Cannot exec %s: %s\n", child[0], strerror(errno));

    return NNS_RUN_EXIT_EXEC;
}
