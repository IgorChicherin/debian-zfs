#!/bin/sh
# ZFSBootMenu early-setup hook: assemble Intel RST / mdadm arrays before
# ZFSBootMenu scans for pools.
#
# Installed to /etc/zfsbootmenu/hooks/early-setup.d/ by
# zbm_setup.py --mdraid. dracut's mdraid udev rules normally do this
# already (with rd.auto=1); this hook is a safety net for imsm volumes that
# are left inactive or appear after udev has settled.

command -v mdadm >/dev/null 2>&1 || exit 0

for mod in vmd md_mod raid0 raid1 raid10; do
    modprobe -q "$mod" 2>/dev/null || true
done

command -v udevadm >/dev/null 2>&1 && udevadm settle --timeout=20

# Assemble everything listed in /etc/mdadm.conf (imsm container + volume)
mdadm --assemble --scan >/dev/null 2>&1 || true
# Start any array that was assembled but left inactive
mdadm --incremental --run --scan >/dev/null 2>&1 || true

if command -v udevadm >/dev/null 2>&1; then
    udevadm trigger --subsystem-match=block --action=change
    udevadm settle --timeout=20
fi

exit 0
