#!/bin/bash
# Gosh Slack Installer - Automated Slackware Installer
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# https://github.com/YOUR_USERNAME/gosh-slack-installer

set -euo pipefail

#=============================================================================
# CONFIGURATION
#=============================================================================
HOSTNAME="slackbox"
TIMEZONE="US/Pacific"
ROOT_PASS="changeme"
SLACK_SOURCE="/mnt/cdrom/slackware64"

#=============================================================================
# AUTO-DETECT TARGET DISK
# Finds the largest non-removable disk that isn't the install media
#=============================================================================
detect_target_disk() {
    local install_disk=""
    
    # Find which disk holds our install source
    if [[ -d "$SLACK_SOURCE" ]]; then
        install_disk=$(df "$SLACK_SOURCE" 2>/dev/null | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//' | xargs basename 2>/dev/null || true)
    fi
    
    # Find largest non-removable disk, excluding install media
    lsblk -dnbo NAME,SIZE,RM,TYPE | \
        awk -v exclude="$install_disk" '$3 == "0" && $4 == "disk" && $1 != exclude {print $2, $1}' | \
        sort -rn | head -1 | awk '{print "/dev/" $2}'
}

TARGET_DISK=$(detect_target_disk)

if [[ -z "$TARGET_DISK" ]] || [[ ! -b "$TARGET_DISK" ]]; then
    echo "Error: Could not auto-detect a suitable target disk" >&2
    exit 1
fi

#=============================================================================
# DERIVED PATHS
#=============================================================================
PART_ROOT="${TARGET_DISK}1"
PART_SWAP="${TARGET_DISK}2"
TARGET="/mnt/target"

#=============================================================================
# SANITY CHECKS
#=============================================================================
if [[ $EUID -ne 0 ]]; then
    echo "Error: Run as root" >&2
    exit 1
fi

if [[ ! -d "$SLACK_SOURCE" ]]; then
    echo "Error: Slackware source not found at $SLACK_SOURCE" >&2
    exit 1
fi

#=============================================================================
# CALCULATE SWAP SIZE (match RAM, cap at 8GB, min 1GB)
#=============================================================================
RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_GB=$(( (RAM_KB + 1048575) / 1048576 ))
SWAP_GB=$RAM_GB
[[ $SWAP_GB -gt 8 ]] && SWAP_GB=8
[[ $SWAP_GB -lt 1 ]] && SWAP_GB=1

#=============================================================================
# DISK SIZE CHECK
#=============================================================================
DISK_SIZE_GB=$(( $(blockdev --getsize64 "$TARGET_DISK") / 1073741824 ))
MIN_SIZE=$(( SWAP_GB + 4 ))

if [[ $DISK_SIZE_GB -lt $MIN_SIZE ]]; then
    echo "Error: Disk too small. Need at least ${MIN_SIZE}GB, have ${DISK_SIZE_GB}GB" >&2
    exit 1
fi

echo "=== GOSH SLACK INSTALLER ==="
echo ""
echo "Auto-detected target: $TARGET_DISK (${DISK_SIZE_GB}GB)"
echo "Root partition: $(( DISK_SIZE_GB - SWAP_GB ))GB"
echo "Swap partition: ${SWAP_GB}GB (based on ${RAM_GB}GB RAM)"
echo ""
echo "This will DESTROY all data on $TARGET_DISK"
echo "Press Ctrl+C within 5 seconds to abort..."
sleep 5

#=============================================================================
# PARTITION
#=============================================================================
echo ">>> Partitioning $TARGET_DISK..."
wipefs -af "$TARGET_DISK"
parted -s "$TARGET_DISK" mklabel msdos
parted -s "$TARGET_DISK" mkpart primary ext4 1MiB "-${SWAP_GB}GiB"
parted -s "$TARGET_DISK" set 1 boot on
parted -s "$TARGET_DISK" mkpart primary linux-swap "-${SWAP_GB}GiB" 100%
partprobe "$TARGET_DISK"
sleep 2

#=============================================================================
# FORMAT
#=============================================================================
echo ">>> Formatting..."
mkfs.ext4 -F "$PART_ROOT"
mkswap "$PART_SWAP"
swapon "$PART_SWAP"

#=============================================================================
# MOUNT TARGET
#=============================================================================
echo ">>> Mounting target..."
mkdir -p "$TARGET"
mount "$PART_ROOT" "$TARGET"

#=============================================================================
# INSTALL PACKAGES
#=============================================================================
echo ">>> Installing packages (this takes a while)..."
for series in a ap d e f k kde l n t tcl x xap xfce y; do
    if [[ -d "$SLACK_SOURCE/$series" ]]; then
        echo "    Installing series: $series"
        for pkg in "$SLACK_SOURCE/$series"/*.t?z; do
            installpkg --root "$TARGET" --terse "$pkg"
        done
    fi
done

#=============================================================================
# CONFIGURE SYSTEM
#=============================================================================
echo ">>> Configuring system..."

cat > "$TARGET/etc/fstab" <<EOF
$PART_ROOT    /         ext4    defaults        1   1
$PART_SWAP    swap      swap    defaults        0   0
devpts        /dev/pts  devpts  gid=5,mode=620  0   0
proc          /proc     proc    defaults        0   0
tmpfs         /dev/shm  tmpfs   nosuid,nodev    0   0
EOF

echo "$HOSTNAME" > "$TARGET/etc/HOSTNAME"
echo "127.0.0.1   localhost $HOSTNAME" > "$TARGET/etc/hosts"

ln -sf "/usr/share/zoneinfo/$TIMEZONE" "$TARGET/etc/localtime"

echo "root:$ROOT_PASS" | chroot "$TARGET" chpasswd

cat > "$TARGET/etc/rc.d/rc.inet1.conf" <<EOF
IPADDR[0]=""
NETMASK[0]=""
USE_DHCP[0]="yes"
DHCP_HOSTNAME[0]="$HOSTNAME"
EOF

#=============================================================================
# BOOTLOADER (LILO)
#=============================================================================
echo ">>> Installing LILO..."
cat > "$TARGET/etc/lilo.conf" <<EOF
boot = $TARGET_DISK
compact
lba32
vga = normal
read-only
timeout = 50
image = /boot/vmlinuz
  root = $PART_ROOT
  label = Linux
EOF

mount --bind /dev "$TARGET/dev"
mount --bind /proc "$TARGET/proc"
mount --bind /sys "$TARGET/sys"

chroot "$TARGET" /sbin/lilo

umount "$TARGET/sys"
umount "$TARGET/proc"
umount "$TARGET/dev"

#=============================================================================
# CLEANUP
#=============================================================================
echo ">>> Cleaning up..."
swapoff "$PART_SWAP"
umount "$TARGET"

echo ""
echo "=== GOSH SLACK INSTALLER COMPLETE ==="
echo "Slackware installed to $TARGET_DISK"
echo "Remove install media and reboot."
