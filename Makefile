.PHONY: build test clean

build:
	./build.sh

test: build
	./tests/test-static.sh
	./tests/test-functions.sh
	./tests/test-list.sh

clean:
	rm -f nns-app-install.sh
