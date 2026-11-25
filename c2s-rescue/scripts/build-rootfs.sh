#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Build a bootable arm64 Debian (trixie) rootfs with Phosh for Samsung Galaxy
# Note20 Ultra 5G (c2s).
#
# Creates an ext4 filesystem image with label 'c2s-root' (<= 8 GB) containing:
#   - systemd, udev, openssh-server, sudo, ca-certificates
#   - Phosh, phoc, squeekboard, gnome-session, fonts
#   - Mesa (Panfrost / KMSRO, EGL/GLES), libinput
#   - NetworkManager, wpasupplicant, iw, firmware-brcm80211
#   - User 'rescue' (uid 1000) autologin via greetd, NO lock screen, NO PIN
#   - Passwordless sudo for 'rescue' (0440 in /etc/sudoers.d/90-rescue)
#   - Stable host SSH keys, key-only SSH login with operator key
#   - Persistent USB gadget network (NCM 192.168.42.1, RNDIS 192.168.62.1)
#   - c2s-flash-boot available at /usr/sbin/c2s-flash-boot
#
# Output:
#   ${OUTDIR}/c2s-root.img (ext4, label c2s-root, default size 6 GiB)

set -euo pipefail
export PATH="/usr/sbin:/sbin:/usr/bin:/bin:${PATH}"

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
RESCUE_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)
REPO_DIR=$(cd -- "${RESCUE_DIR}/.." && pwd)

OUTDIR="${C2S_ROOTFS_OUTDIR:-/home/gregor/phone-second-life-data/mb008/build}"
IMAGE_SIZE_G="${C2S_ROOTFS_SIZE_G:-6}"
IMAGE_NAME="${C2S_ROOTFS_IMAGE_NAME:-c2s-root.img}"
SUITE="${C2S_DEBIAN_SUITE:-trixie}"
MIRROR="${C2S_DEBIAN_MIRROR:-http://deb.debian.org/debian}"

AUTHKEYS="${C2S_AUTHORIZED_KEYS:-${HOME}/.ssh/id_ed25519.pub}"
if [ ! -f "${AUTHKEYS}" ]; then
    echo "ERROR: operator public key not found at ${AUTHKEYS}" >&2
    exit 1
fi

mkdir -p "${OUTDIR}"
IMAGE="${OUTDIR}/${IMAGE_NAME}"
LOG="${OUTDIR}/build-rootfs.log"
: > "${LOG}"

step() {
    echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) :: $*" | tee -a "${LOG}"
}

step "Checking host dependencies"
for cmd in mmdebstrap qemu-aarch64 truncate mkfs.ext4; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: missing required command: $cmd" >&2
        exit 1
    fi
done

if [ "${REUSE_BOOTSTRAP:-0}" = "1" ] && [ -f "${IMAGE}" ]; then
    step "Reusing existing bootstrap image at ${IMAGE}"
else
    step "Creating empty ${IMAGE_SIZE_G}G ext4 image at ${IMAGE}"
    rm -f "${IMAGE}"
    truncate -s "${IMAGE_SIZE_G}G" "${IMAGE}"
    mkfs.ext4 -F -L "c2s-root" -b 4096 -m 1 "${IMAGE}" >> "${LOG}" 2>&1
fi

MNT=$(mktemp -d /tmp/c2s-rootfs-mnt.XXXXXX)
cleanup() {
    step "Cleaning up temporary mount"
    set +e
    if mountpoint -q "${MNT}"; then
        sudo -n umount -R "${MNT}" >> "${LOG}" 2>&1 || true
    fi
    rm -rf "${MNT}"
}
trap cleanup EXIT

step "Mounting image on ${MNT}"
sudo -n mount -o loop "${IMAGE}" "${MNT}"

if [ "${REUSE_BOOTSTRAP:-0}" = "1" ] && [ -f "${MNT}/etc/debian_version" ]; then
    step "Debian base already present (suite $(cat "${MNT}/etc/debian_version" 2>/dev/null || true)), skipping mmdebstrap"
else
    step "Bootstrapping Debian ${SUITE} (arm64) with mmdebstrap"
    PACKAGES=(
        # Base system
        systemd systemd-sysv udev dbus-broker
        sudo openssh-server ca-certificates curl nano less procps psmisc iproute2 e2fsprogs
        # Display & Phosh
        phosh phoc squeekboard phosh-mobile-tweaks gnome-session-bin gnome-settings-daemon greetd
        # Mesa & GPU & Input
        libgl1-mesa-dri libegl-mesa0 libgles2 mesa-utils mesa-utils-bin libinput-bin libinput-tools grim
        # Networking & Wi-Fi
        network-manager wpasupplicant iw firmware-brcm80211
        # Fonts
        fonts-dejavu-core fonts-lato
    )
    PKG_LIST=$(IFS=,; echo "${PACKAGES[*]}")

    sudo -n mmdebstrap \
        --mode=sudo \
        --architectures=arm64 \
        --variant=minbase \
        --components="main,non-free-firmware" \
        --include="${PKG_LIST}" \
        "${SUITE}" "${MNT}" "${MIRROR}" >> "${LOG}" 2>&1
fi

step "Customizing rootfs (users, sudo, ssh, greetd, phosh, gadget)"

# 1. Hostname & hosts
echo "c2s" | sudo -n tee "${MNT}/etc/hostname" > /dev/null
sudo -n tee "${MNT}/etc/hosts" > /dev/null <<'EOF'
127.0.0.1   localhost c2s
::1         localhost ip6-localhost ip6-loopback
EOF

# 2. fstab (passno 0 disables systemd-fsck-root on already-mounted rootfs)
sudo -n tee "${MNT}/etc/fstab" > /dev/null <<'EOF'
LABEL=c2s-root  /  ext4  errors=remount-ro,noatime  0  0
EOF

# 3. Environment & Panfrost settings
sudo -n tee "${MNT}/etc/environment" > /dev/null <<'EOF'
PAN_MESA_DEBUG=noafbc
EOF

# 4. User rescue (uid 1000)
if ! sudo -n chroot "${MNT}" id -u rescue >/dev/null 2>&1; then
    sudo -n chroot "${MNT}" useradd -m -u 1000 -s /bin/bash \
        -G sudo,video,input,render,audio,plugdev,dialout,netdev rescue >> "${LOG}" 2>&1
fi
sudo -n chroot "${MNT}" passwd -d rescue >> "${LOG}" 2>&1 || true

# 5. Sudoers for rescue
sudo -n tee "${MNT}/etc/sudoers.d/90-rescue" > /dev/null <<'EOF'
rescue ALL=(ALL:ALL) NOPASSWD: ALL
EOF
sudo -n chmod 0440 "${MNT}/etc/sudoers.d/90-rescue"
sudo -n chown 0:0 "${MNT}/etc/sudoers.d/90-rescue"

# 6. SSH authorized_keys (both rescue and root)
sudo -n mkdir -p "${MNT}/home/rescue/.ssh" "${MNT}/root/.ssh"
sudo -n cp "${AUTHKEYS}" "${MNT}/home/rescue/.ssh/authorized_keys"
sudo -n cp "${AUTHKEYS}" "${MNT}/root/.ssh/authorized_keys"
sudo -n chmod 0700 "${MNT}/home/rescue/.ssh" "${MNT}/root/.ssh"
sudo -n chmod 0600 "${MNT}/home/rescue/.ssh/authorized_keys" "${MNT}/root/.ssh/authorized_keys"
sudo -n chown -R 1000:1000 "${MNT}/home/rescue/.ssh"
sudo -n chown -R 0:0 "${MNT}/root/.ssh"

# 7. Stable SSH host keys (generate if missing, never prompt for overwrite)
if [ ! -f "${MNT}/etc/ssh/ssh_host_ed25519_key" ]; then
    sudo -n ssh-keygen -t ed25519 -N "" -f "${MNT}/etc/ssh/ssh_host_ed25519_key" >> "${LOG}" 2>&1
fi
if [ ! -f "${MNT}/etc/ssh/ssh_host_rsa_key" ]; then
    sudo -n ssh-keygen -t rsa -b 3072 -N "" -f "${MNT}/etc/ssh/ssh_host_rsa_key" >> "${LOG}" 2>&1
fi
sudo -n chmod 0600 "${MNT}"/etc/ssh/ssh_host_*_key
sudo -n chmod 0644 "${MNT}"/etc/ssh/ssh_host_*_key.pub

# 8. Key-only SSH daemon configuration
sudo -n mkdir -p "${MNT}/etc/ssh/sshd_config.d"
sudo -n tee "${MNT}/etc/ssh/sshd_config.d/c2s-rescue.conf" > /dev/null <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
EOF

# 9. Greetd autologin directly into Phosh
sudo -n mkdir -p "${MNT}/etc/greetd"
sudo -n tee "${MNT}/etc/greetd/config.toml" > /dev/null <<'EOF'
[terminal]
vt = 1

[default_session]
command = "phosh-session"
user = "rescue"

[initial_session]
command = "phosh-session"
user = "rescue"
EOF

# 10. Disable lock screen, idle sleep, and PIN in GNOME/Phosh
sudo -n mkdir -p "${MNT}/etc/dconf/profile" "${MNT}/etc/dconf/db/local.d"
sudo -n tee "${MNT}/etc/dconf/profile/user" > /dev/null <<'EOF'
user-db:user
system-db:local
EOF

sudo -n tee "${MNT}/etc/dconf/db/local.d/00-no-lock" > /dev/null <<'EOF'
[org/gnome/desktop/screensaver]
lock-enabled=false
idle-activation-enabled=false

[org/gnome/desktop/session]
idle-delay=uint32 0

[org/gnome/desktop/lockdown]
disable-lock-screen=true
EOF

sudo -n chroot "${MNT}" dconf update >> "${LOG}" 2>&1 || true

# 11. Disable systemd suspend/sleep (prevent USB loss lockup)
sudo -n mkdir -p "${MNT}/etc/systemd/sleep.conf.d"
sudo -n tee "${MNT}/etc/systemd/sleep.conf.d/10-c2s-no-suspend.conf" > /dev/null <<'EOF'
[Sleep]
AllowSuspend=no
AllowHibernation=no
AllowSuspendThenHibernate=no
AllowHybridSleep=no
EOF

sudo -n chroot "${MNT}" systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >> "${LOG}" 2>&1 || true

# 12. USB Gadget network initializer script & service
sudo -n mkdir -p "${MNT}/usr/lib" "${MNT}/usr/sbin"
sudo -n cp "${RESCUE_DIR}/initramfs/usr/lib/c2s-gadget.sh" "${MNT}/usr/lib/c2s-gadget.sh"
sudo -n chmod 0644 "${MNT}/usr/lib/c2s-gadget.sh"

# Copy c2s-flash-boot so boot can still be reflashed from the running rootfs
sudo -n cp "${RESCUE_DIR}/initramfs/usr/sbin/c2s-flash-boot" "${MNT}/usr/sbin/c2s-flash-boot"
sudo -n chmod 0755 "${MNT}/usr/sbin/c2s-flash-boot"

sudo -n tee "${MNT}/usr/sbin/c2s-gadget-init" > /dev/null <<'EOF'
#!/bin/sh
mount -t configfs configfs /sys/kernel/config 2>/dev/null || true
if [ ! -d /sys/kernel/config/usb_gadget/g1 ]; then
    if [ -r /usr/lib/c2s-gadget.sh ]; then
        . /usr/lib/c2s-gadget.sh
        c2s_gadget_setup || true
    fi
fi

# Ensure NCM and RNDIS have their rescue IPs assigned and are up
for iface in ncm0 usb0; do
    if [ -d "/sys/class/net/${iface}" ]; then
        ip addr add 192.168.42.1/24 dev "${iface}" 2>/dev/null || true
        ip link set "${iface}" up 2>/dev/null || true
        break
    fi
done

for iface in rndis0 usb1; do
    if [ -d "/sys/class/net/${iface}" ]; then
        ip addr add 192.168.62.1/24 dev "${iface}" 2>/dev/null || true
        ip link set "${iface}" up 2>/dev/null || true
        break
    fi
done
exit 0
EOF
sudo -n chmod 0755 "${MNT}/usr/sbin/c2s-gadget-init"

sudo -n tee "${MNT}/etc/systemd/system/c2s-gadget.service" > /dev/null <<'EOF'
[Unit]
Description=C2S USB Gadget Network Initializer
DefaultDependencies=no
After=local-fs.target
Before=network-pre.target ssh.service
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/c2s-gadget-init

[Install]
WantedBy=sysinit.target
EOF

# NetworkManager: keep gadget and usb interfaces unmanaged
sudo -n mkdir -p "${MNT}/etc/NetworkManager/conf.d"
sudo -n tee "${MNT}/etc/NetworkManager/conf.d/10-unmanaged-usb.conf" > /dev/null <<'EOF'
[keyfile]
unmanaged-devices=interface-name:ncm*;interface-name:rndis*;interface-name:usb*;interface-name:enx*
EOF

# Ensure /run/sshd is created with proper permissions before sshd starts
sudo -n mkdir -p "${MNT}/etc/systemd/system/ssh.service.d"
sudo -n tee "${MNT}/etc/systemd/system/ssh.service.d/10-runtime-dir.conf" > /dev/null <<'EOF'
[Service]
ExecStartPre=/bin/mkdir -p -m 0755 /run/sshd
EOF

# Install dropbear fallback binary and service on port 2222
DROPBEAR_SRC="/tmp/opencode/c2s-diag20-out/work/dropbear-src/dropbear"
if [ -f "${DROPBEAR_SRC}" ]; then
    sudo -n cp "${DROPBEAR_SRC}" "${MNT}/usr/sbin/dropbear-static"
    sudo -n chmod 0755 "${MNT}/usr/sbin/dropbear-static"
    sudo -n tee "${MNT}/etc/systemd/system/dropbear-emergency.service" > /dev/null <<'EOF'
[Unit]
Description=Emergency Dropbear SSH Server
After=c2s-gadget.service network.target
Before=ssh.service

[Service]
Type=forking
ExecStart=/usr/sbin/dropbear-static -R -E -b /etc/issue -p 192.168.42.1:2222 -p 192.168.62.1:2222
Restart=always

[Install]
WantedBy=multi-user.target sysinit.target
EOF
fi

# Enable services in chroot
sudo -n chroot "${MNT}" systemctl enable ssh.service ssh.socket greetd.service c2s-gadget.service >> "${LOG}" 2>&1 || true
sudo -n mkdir -p "${MNT}/etc/systemd/system/graphical.target.wants" "${MNT}/etc/systemd/system/getty.target.wants" "${MNT}/etc/systemd/system/multi-user.target.wants" "${MNT}/etc/systemd/system/sysinit.target.wants"
sudo -n ln -sf /usr/lib/systemd/system/greetd.service "${MNT}/etc/systemd/system/display-manager.service"
sudo -n ln -sf /usr/lib/systemd/system/greetd.service "${MNT}/etc/systemd/system/graphical.target.wants/display-manager.service"
sudo -n ln -sf /usr/lib/systemd/system/greetd.service "${MNT}/etc/systemd/system/graphical.target.wants/greetd.service"
sudo -n ln -sf /usr/lib/systemd/system/serial-getty@.service "${MNT}/etc/systemd/system/getty.target.wants/serial-getty@ttyGS0.service"
if [ -f "${MNT}/etc/systemd/system/dropbear-emergency.service" ]; then
    sudo -n ln -sf /etc/systemd/system/dropbear-emergency.service "${MNT}/etc/systemd/system/multi-user.target.wants/dropbear-emergency.service"
    sudo -n ln -sf /etc/systemd/system/dropbear-emergency.service "${MNT}/etc/systemd/system/sysinit.target.wants/dropbear-emergency.service"
fi

step "Syncing and unmounting image"
sync
sudo -n umount -R "${MNT}"

step "Checking filesystem"
e2fsck -f -y "${IMAGE}" >> "${LOG}" 2>&1 || true

step "Verifying image metadata"
ACTUAL_LABEL=$(e2label "${IMAGE}")
ACTUAL_SIZE=$(stat -c %s "${IMAGE}")
ACTUAL_SHA256=$(sha256sum "${IMAGE}" | awk '{print $1}')

echo "Image built successfully:"
echo "  Path:   ${IMAGE}"
echo "  Label:  ${ACTUAL_LABEL}"
echo "  Size:   ${ACTUAL_SIZE} bytes"
echo "  SHA256: ${ACTUAL_SHA256}"

echo "${ACTUAL_SHA256}  ${IMAGE_NAME}" > "${IMAGE}.sha256"
step "Done"
