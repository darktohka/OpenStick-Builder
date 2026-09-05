#!/bin/sh -e
set -e
set -x

CHROOT=${CHROOT=$(pwd)/rootfs}
RELEASE=${RELEASE=sid}
HOST_NAME=${HOST_NAME=openstick-debian}

rm -rf ${CHROOT}

debootstrap --foreign --arch arm64 \
    --keyring /usr/share/keyrings/debian-archive-keyring.gpg ${RELEASE} ${CHROOT}

chroot ${CHROOT} /bin/bash /debootstrap/debootstrap --second-stage

cat << EOF > ${CHROOT}/etc/apt/sources.list
deb http://deb.debian.org/debian ${RELEASE} main contrib non-free-firmware
EOF

mount -t proc proc ${CHROOT}/proc/
mount -t sysfs sys ${CHROOT}/sys/
mount -o bind /dev/ ${CHROOT}/dev/
mount -o bind /dev/pts/ ${CHROOT}/dev/pts/
mount -o bind /run ${CHROOT}/run/

cp scripts/setup.sh ${CHROOT}
chroot ${CHROOT} /bin/sh -c /setup.sh

# cleanup
for a in proc sys dev/pts dev run; do
    umount ${CHROOT}/${a}
done;

rm -f ${CHROOT}/setup.sh
echo -n > ${CHROOT}/root/.bash_history

echo ${HOST_NAME} > ${CHROOT}/etc/hostname
sed -i "/localhost/ s/$/ ${HOST_NAME}/" ${CHROOT}/etc/hosts

# setup systemd services.
#
# configs/system/ is copied verbatim into /etc/systemd/system, including the
# *.wants/ symlink trees, which is what enables the units for their targets
# (multi-user.target.wants/, timers.target.wants/, usb-gadget.target.wants/).
# Units enabled this way: cleanup-wwan, disable-cpu-cores, dnsmasq-openstick,
# msm-firmware-loader, openstick-hotspot, usb-gadget, wwan-watchdog.
cp -a configs/system/* ${CHROOT}/etc/systemd/system

cp -a scripts/msm-firmware-loader.sh ${CHROOT}/usr/sbin
cp -a scripts/openstick-hotspot-setup.sh ${CHROOT}/usr/local/sbin
# cleanup-wwan is ExecStart'd by cleanup-wwan.service
cp -a scripts/cleanup-wwan ${CHROOT}/usr/local/sbin
# wwan-watchdog is ExecStart'd by wwan-watchdog.service (timer-enabled)
cp -a scripts/wwan-watchdog ${CHROOT}/usr/local/sbin

# setup NetworkManager + wifi hotspot
mkdir -p ${CHROOT}/etc/NetworkManager ${CHROOT}/etc/hostapd
cp configs/NetworkManager.conf ${CHROOT}/etc/NetworkManager/NetworkManager.conf
cp configs/hostapd.conf ${CHROOT}/etc/hostapd/hostapd.conf
cp configs/dnsmasq-openstick.conf ${CHROOT}/etc/dnsmasq-openstick.conf

# setup the NM-managed wired/LTE connections (usb0 and wwan0)
#
# The wifi hotspot (wlan0) is intentionally NOT set up as an NM connection:
# NetworkManager's hotspot feature relies on wpa_supplicant, which races with
# the wcn36xx driver's scans and fails to bring up the access point. wlan0 is
# served by hostapd instead (see docs/hotspot.md). NM is told to leave wlan0
# alone via the [keyfile] unmanaged-devices entry in NetworkManager.conf, so
# the old bundled hotspot.nmconnection is dropped to avoid confusion.
cp configs/lte.nmconnection configs/usb.nmconnection ${CHROOT}/etc/NetworkManager/system-connections
chmod 0600 ${CHROOT}/etc/NetworkManager/system-connections/*

# enable autoconnect for usb0
cat << EOF > ${CHROOT}/etc/udev/rules.d/99-nm-usb0.rules
SUBSYSTEM=="net", ACTION=="add|change|move", ENV{DEVTYPE}=="gadget", ENV{NM_UNMANAGED}="0"
EOF

# install kernel
wget -O - http://mirror.postmarketos.org/postmarketos/v24.06/aarch64/linux-postmarketos-qcom-msm8916-6.6-r5.apk \
    | tar xkzf - -C ${CHROOT} --exclude=.PKGINFO --exclude=.SIGN* 2>/dev/null

mkdir -p ${CHROOT}/boot/extlinux
cp configs/extlinux.conf ${CHROOT}/boot/extlinux

# copy custom dtb's
cp dtbs/* ${CHROOT}/boot/dtbs/qcom

# create missing directory
mkdir -p ${CHROOT}/lib/firmware/msm-firmware-loader

# update fstab
echo "PARTUUID=80780b1d-0fe1-27d3-23e4-9244e62f8c46\t/boot\text2\tdefaults\t0 2" > ${CHROOT}/etc/fstab

# setup sms-gateway.
#
# The binary itself is staged into dist/usr/local/bin by build_sms_gateway.sh
# and lands on the final rootfs via build_images.sh's `cp -a dist/* mnt`. The
# config file and the runtime directory it points at are created here so the
# unit can start on first boot. The service is enabled through the
# multi-user.target.wants symlink in configs/system/.
mkdir -p ${CHROOT}/opt/sms-gateway
cp configs/sms-gateway/sms-gateway.conf ${CHROOT}/opt/sms-gateway/sms-gateway.conf

# Reserve /dev/wwan0at1 for sms-gateway so ModemManager leaves it alone
# (ModemManager keeps /dev/wwan0at0 + /dev/wwan0qmi0 for the wwan0 data link).
mkdir -p ${CHROOT}/etc/udev/rules.d
cp configs/udev/rules.d/99-sms-gateway.rules ${CHROOT}/etc/udev/rules.d/99-sms-gateway.rules

# setup frpc.
#
# The binary itself is staged into dist/usr/local/bin by build_frpc.sh and
# lands on the final rootfs via build_images.sh's `cp -a dist/* mnt`. The
# config template is created here so the unit has something to read. Unlike
# sms-gateway, frpc is intentionally NOT enabled by default: there is no
# multi-user.target.wants symlink for it, and the config ships with a
# placeholder server, so it only starts once the user fills in their frps
# details and runs `systemctl enable --now frpc`. The unit itself is installed
# by the configs/system/ copy above.
mkdir -p ${CHROOT}/etc/frp
cp configs/frp/frpc.toml ${CHROOT}/etc/frp/frpc.toml

# backup rootfs
tar cpzf rootfs.tgz -C rootfs .

echo "done"
