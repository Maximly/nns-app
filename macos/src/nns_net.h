/*++

Abstract:

    Shared IPv4 local-destination policy for the macOS nns-app launcher and
    DYLD interposer. Destinations in these classes stay on the host stack and
    must not be forced onto the managed utun.

Revision History:

    11/13/2026 - Maxim Lyadvinsky - Created

--*/
#ifndef NNS_NET_H
#define NNS_NET_H

#include <stdint.h>

/* IPv4 class checks on host-order addresses */
enum nns_ipv4_class {
    NNS_IPV4_OCTET_SHIFT = 24,
    NNS_IPV4_LOOPBACK_OCTET = 127, /* 127.0.0.0/8 */
    NNS_IPV4_THIS_OCTET = 0,       /* 0.0.0.0/8 */
    NNS_IPV4_MULTICAST_OCTET = 224 /* 224.0.0.0/4 and above */
};

#define NNS_IPV4_LINKLOCAL_MASK 0xffff0000u
#define NNS_IPV4_LINKLOCAL_NET  0xa9fe0000u /* 169.254.0.0/16 */

/**
 * nns_ipv4_is_host_local() - whether a host-order IPv4 stays on the host stack
 * @host_order: destination address in host byte order
 *
 * Loopback, 0/8, multicast, and IPv4 link-local are not sent through the tunnel.
 *
 * Return: non-zero when the address is host-local
 */
static inline int nns_ipv4_is_host_local(uint32_t host_order)
{
    unsigned octet = host_order >> NNS_IPV4_OCTET_SHIFT;

    return octet == NNS_IPV4_LOOPBACK_OCTET ||
        octet == NNS_IPV4_THIS_OCTET ||
        octet >= NNS_IPV4_MULTICAST_OCTET ||
        (host_order & NNS_IPV4_LINKLOCAL_MASK) == NNS_IPV4_LINKLOCAL_NET;
}

#endif /* NNS_NET_H */
