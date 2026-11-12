.PHONY: build test clean

build:
	./build.sh

test: build
	./tests/test-static.sh
	./tests/test-install-amnezia.sh
	./tests/test-auto-mtu.sh
	./tests/test-mtu-hook.sh
	./tests/test-myloc.sh
	./tests/test-git-via.sh
	./tests/test-functions.sh
	./tests/test-list.sh
	./tests/test-unified-commands.sh
	./tests/test-managed-clients.sh
	./tests/test-set-via.sh
	./tests/test-server-reinstall.sh
	./tests/test-gateway-autoconfig.sh
	./tests/test-remote-downgrade.sh
	./tests/test-cloak-server.sh
	./tests/test-fixed-ip.sh
	./tests/test-client-routing.sh
	./tests/test-backup.sh
	./tests/test-amneziawg.sh
	./tests/test-awg-server.sh
	./tests/test-split-tunnel.sh
	./tests/test-split-dns.sh
	./tests/test-nsswitch.sh
	./tests/test-wg-apparmor.sh

clean:
	rm -f nns-app-install.sh
