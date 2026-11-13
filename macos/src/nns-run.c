/*++

Abstract:

    Experimental launcher: insert libnnsbind.dylib for an unrestricted macOS executable

Revision History:

    10/11/2026 - Maxim Lyadvinsky - Created

--*/
#include <arpa/inet.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>


static void usage(const char* name)
 {
    fprintf(stderr,
        "Usage: %s --vpn-ip IPv4 --vpn-if utunN --lib /absolute/path/libnnsbind.dylib [--debug] -- command [args...]\n"
        "SIP/hardened apps can ignore injection; not a sandbox.\n",
        name);
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

    if (!ip || !iface || !lib || cmd < 0 || cmd >= argc || lib[0] != '/') {
        usage(argv[0]); return 2;
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

    execvp(argv[cmd], argv + cmd);
    fprintf(stderr, "Cannot exec %s: %s\n", argv[cmd], strerror(errno));
    return 127;
}
