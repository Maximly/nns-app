.PHONY: build test clean

build:
	./build.sh

test: build
	./tests/test-static.sh
	./tests/test-functions.sh
	./tests/test-list.sh
	./tests/test-unified-commands.sh
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

clean:
	rm -f nns-app-install.sh
