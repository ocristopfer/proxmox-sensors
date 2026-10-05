# Common tasks. Nothing here is needed to use the project — only to work on it.

SHELL_SCRIPTS = run.sh packaging/build-deb.sh packaging/pve-sensors \
                packaging/debian/postinst packaging/debian/prerm packaging/debian/postrm \
                tests/run-tests.sh

.PHONY: all lint test deb clean

all: lint test

lint:
	cd src && shellcheck -x -S warning proxmox-enable-sensors.sh
	shellcheck -S warning $(SHELL_SCRIPTS)

# the --dry-run end-to-end test only runs as root
test:
	tests/run-tests.sh

deb:
	packaging/build-deb.sh $(VERSION)

clean:
	rm -rf dist
