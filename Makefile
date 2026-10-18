PYTHON ?= python3
ISO ?= output/debian-zfs-live.iso
IMAGE ?= debian-zfs-builder
WORK_VOLUME ?= debian-zfs-work
MEMORY ?= 4096
CPUS ?= 4

.PHONY: test build docker-build docker-clean vm usb check clean

test:
	$(PYTHON) -m unittest discover -s tests -v

build:
	sudo $(PYTHON) scripts/build_iso.py

# The live-build tree lives in a Docker volume: a bind-mounted checkout can be nodev (e.g. ZFS devices=off),
# and then the device nodes in the chroot are unusable ("cannot create /dev/null: Permission denied").
# The fixed container name allows one build at a time: builds share the volume and `lb clean` would wipe the other's chroot.
# ARGS passes options to build_iso.py, e.g. make docker-build ARGS="--macbook --release sid"
docker-build:
	docker build -t $(IMAGE) docker
	docker run --rm --privileged --name $(IMAGE)-build -e PYTHONDONTWRITEBYTECODE=1 -v $(CURDIR):/src -v $(WORK_VOLUME):/src/live-build-work \
	  -e HOST_UID=$$(id -u) -e HOST_GID=$$(id -g) $(IMAGE) \
	  sh -c 'python3 scripts/build_iso.py --yes $(ARGS); rc=$$?; chown -R $$HOST_UID:$$HOST_GID output 2>/dev/null; exit $$rc'

docker-clean:
	docker volume rm $(WORK_VOLUME)

vm:
	$(PYTHON) scripts/test-vm.py $(ISO) --memory $(MEMORY) --cpus $(CPUS)

usb:
	sudo $(PYTHON) scripts/usb-write.py $(USB) $(ISO)

check:
	@command -v docker >/dev/null && echo "ok      docker (make docker-build)" || echo "MISSING docker (only needed for make docker-build)"
	@for t in lb qemu-system-x86_64 sha256sum; do \
	  command -v $$t >/dev/null && echo "ok      $$t" || echo "MISSING $$t"; done
	@ls /usr/share/OVMF/OVMF_CODE*.fd /usr/share/edk2/x64/OVMF_CODE*.fd /usr/share/edk2/ovmf/OVMF_CODE.fd 2>/dev/null | grep -q . \
	  && echo "ok      OVMF" || echo "MISSING OVMF (apt install ovmf / pacman -S edk2-ovmf)"

clean:
	rm -rf live-build-work output
