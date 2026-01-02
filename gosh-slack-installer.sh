#!/bin/bash
# Gosh Slack Installer - Automated Slackware Installer
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# https://github.com/YOUR_USERNAME/gosh-slack-installer

set -euo pipefail

#=============================================================================
# CONFIGURATION
#=============================================================================
HOSTNAME="${HOSTNAME:-slackbox}"
TIMEZONE="${TIMEZONE:-US/Pacific}"
ROOT_PASS="${ROOT_PASS:-changeme}"

#=============================================================================
# AUTO-DETECT SLACKWARE SOURCE
#=============================================================================
detect_slack_source() {
    local search_paths=(
        "/mnt/cdrom/slackware64"
        "/mnt/cdrom/slackware"
        "/mnt/slackware64"
        "/mnt/slackware"
        "/cdrom/slackware64"
        "/cdrom/slackware"
    )

    for path in "${search_paths[@]}"; do
        if [[ -d "$path" ]] && [[ -d "$path/a" ]]; then
            echo "$path"
            return 0
        fi
    done

    # Try to find it anywhere under common mount points
    for base in /mnt /cdrom /media; do
        if [[ -d "$base" ]]; then
            local found=$(find "$base" -maxdepth 2 -type d -name "slackware64" 2>/dev/null | head -1)
            if [[ -n "$found" ]] && [[ -d "$found/a" ]]; then
                echo "$found"
                return 0
            fi
            found=$(find "$base" -maxdepth 2 -type d -name "slackware" 2>/dev/null | head -1)
            if [[ -n "$found" ]] && [[ -d "$found/a" ]]; then
                echo "$found"
                return 0
            fi
        fi
    done

    return 1
}

SLACK_SOURCE="${SLACK_SOURCE:-$(detect_slack_source || echo "")}"

#=============================================================================
# BOOT MODE DETECTION
#=============================================================================
detect_boot_mode() {
    if [[ -d /sys/firmware/efi ]]; then
        echo "uefi"
    else
        echo "bios"
    fi
}

BOOT_MODE=$(detect_boot_mode)

#=============================================================================
# AUTO-DETECT TARGET DISK
# Finds the largest non-removable disk that isn't the install media
#=============================================================================
detect_target_disk() {
    local install_disk=""
    
    # Find which disk holds our install source
    if [[ -d "$SLACK_SOURCE" ]]; then
        install_disk=$(df "$SLACK_SOURCE" 2>/dev/null | tail -1 | awk '{print $1}' | sed 's/p\?[0-9]*$//' | xargs basename 2>/dev/null || true)
    fi
    
    # Find largest non-removable disk, excluding install media
    lsblk -dnbo NAME,SIZE,RM,TYPE | \
        awk -v exclude="$install_disk" '$3 == "0" && $4 == "disk" && $1 != exclude {print $2, $1}' | \
        sort -rn | head -1 | awk '{print "/dev/" $2}'
}

#=============================================================================
# PARTITION NAMING HELPER
# Handles NVMe (/dev/nvme0n1p1) vs SATA/virtio (/dev/sda1) naming
#=============================================================================
get_partition_path() {
    local disk="$1"
    local num="$2"
    
    # NVMe and certain other devices use 'p' separator
    if [[ "$disk" =~ nvme[0-9]+n[0-9]+$ ]] || \
       [[ "$disk" =~ mmcblk[0-9]+$ ]] || \
       [[ "$disk" =~ loop[0-9]+$ ]] || \
       [[ "$disk" =~ nbd[0-9]+$ ]]; then
        echo "${disk}p${num}"
    else
        echo "${disk}${num}"
    fi
}

#=============================================================================
# DETECT AND VALIDATE
#=============================================================================
TARGET_DISK=$(detect_target_disk)

if [[ -z "$TARGET_DISK" ]] || [[ ! -b "$TARGET_DISK" ]]; then
    echo "Error: Could not auto-detect a suitable target disk" >&2
    echo "Available disks:" >&2
    lsblk -dno NAME,SIZE,TYPE,RM | grep -E "disk\s+0$" >&2
    exit 1
fi

#=============================================================================
# DERIVED PATHS (using partition helper)
#=============================================================================
if [[ "$BOOT_MODE" == "uefi" ]]; then
    PART_EFI=$(get_partition_path "$TARGET_DISK" 1)
    PART_ROOT=$(get_partition_path "$TARGET_DISK" 2)
    PART_SWAP=$(get_partition_path "$TARGET_DISK" 3)
else
    PART_ROOT=$(get_partition_path "$TARGET_DISK" 1)
    PART_SWAP=$(get_partition_path "$TARGET_DISK" 2)
fi

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
if [[ "$BOOT_MODE" == "uefi" ]]; then
    MIN_SIZE=$(( SWAP_GB + 5 ))  # Extra for EFI partition
else
    MIN_SIZE=$(( SWAP_GB + 4 ))
fi

if [[ $DISK_SIZE_GB -lt $MIN_SIZE ]]; then
    echo "Error: Disk too small. Need at least ${MIN_SIZE}GB, have ${DISK_SIZE_GB}GB" >&2
    exit 1
fi

#=============================================================================
# SUMMARY
#=============================================================================
echo "=== GOSH SLACK INSTALLER ==="
echo ""
echo "Boot mode:      $BOOT_MODE"
echo "Target disk:    $TARGET_DISK (${DISK_SIZE_GB}GB)"
if [[ "$BOOT_MODE" == "uefi" ]]; then
    echo "EFI partition:  512MB"
    echo "Root partition: $(( DISK_SIZE_GB - SWAP_GB - 1 ))GB"
else
    echo "Root partition: $(( DISK_SIZE_GB - SWAP_GB ))GB"
fi
echo "Swap partition: ${SWAP_GB}GB (based on ${RAM_GB}GB RAM)"
echo ""
echo "This will DESTROY all data on $TARGET_DISK"
echo "Press Ctrl+C within 5 seconds to abort..."
sleep 5

#=============================================================================
# PARTITION
#=============================================================================
echo ">>> Partitioning $TARGET_DISK ($BOOT_MODE mode)..."
if command -v wipefs >/dev/null 2>&1; then
    wipefs -af "$TARGET_DISK"
elif command -v sgdisk >/dev/null 2>&1; then
    sgdisk --zap-all "$TARGET_DISK"
else
    # Fallback: clear the first/last 10MiB to remove old signatures/partition tables.
    DISK_SIZE_BYTES=$(blockdev --getsize64 "$TARGET_DISK")
    DISK_SIZE_MB=$(( DISK_SIZE_BYTES / 1048576 ))
    dd if=/dev/zero of="$TARGET_DISK" bs=1M count=10 conv=fsync
    if [[ "$DISK_SIZE_MB" -gt 20 ]]; then
        dd if=/dev/zero of="$TARGET_DISK" bs=1M count=10 seek=$(( DISK_SIZE_MB - 10 )) conv=fsync
    fi
fi

if [[ "$BOOT_MODE" == "uefi" ]]; then
    # GPT with EFI System Partition
    parted -s "$TARGET_DISK" mklabel gpt
    parted -s "$TARGET_DISK" mkpart "EFI" fat32 1MiB 513MiB
    parted -s "$TARGET_DISK" set 1 esp on
    parted -s "$TARGET_DISK" mkpart "Linux" ext4 513MiB "-${SWAP_GB}GiB"
    parted -s "$TARGET_DISK" mkpart "Swap" linux-swap "-${SWAP_GB}GiB" 100%
else
    # MBR for BIOS
    parted -s "$TARGET_DISK" mklabel msdos
    parted -s "$TARGET_DISK" mkpart primary ext4 1MiB "-${SWAP_GB}GiB"
    parted -s "$TARGET_DISK" set 1 boot on
    parted -s "$TARGET_DISK" mkpart primary linux-swap "-${SWAP_GB}GiB" 100%
fi

partprobe "$TARGET_DISK"
sleep 2

#=============================================================================
# FORMAT
#=============================================================================
echo ">>> Formatting..."
if [[ "$BOOT_MODE" == "uefi" ]]; then
    mkfs.fat -F32 "$PART_EFI"
fi
mkfs.ext4 -F "$PART_ROOT"
mkswap "$PART_SWAP"
swapon "$PART_SWAP"

#=============================================================================
# MOUNT TARGET
#=============================================================================
echo ">>> Mounting target..."
mkdir -p "$TARGET"
mount "$PART_ROOT" "$TARGET"

if [[ "$BOOT_MODE" == "uefi" ]]; then
    mkdir -p "$TARGET/boot/efi"
    mount "$PART_EFI" "$TARGET/boot/efi"
fi

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

# fstab
if [[ "$BOOT_MODE" == "uefi" ]]; then
    cat > "$TARGET/etc/fstab" <<EOF
$PART_ROOT    /            ext4    defaults        1   1
$PART_EFI     /boot/efi    vfat    defaults        0   2
$PART_SWAP    swap         swap    defaults        0   0
devpts        /dev/pts     devpts  gid=5,mode=620  0   0
proc          /proc        proc    defaults        0   0
tmpfs         /dev/shm     tmpfs   nosuid,nodev    0   0
EOF
else
    cat > "$TARGET/etc/fstab" <<EOF
$PART_ROOT    /         ext4    defaults        1   1
$PART_SWAP    swap      swap    defaults        0   0
devpts        /dev/pts  devpts  gid=5,mode=620  0   0
proc          /proc     proc    defaults        0   0
tmpfs         /dev/shm  tmpfs   nosuid,nodev    0   0
EOF
fi

# Hostname
echo "$HOSTNAME" > "$TARGET/etc/HOSTNAME"
echo "127.0.0.1   localhost $HOSTNAME" > "$TARGET/etc/hosts"

# Timezone
ln -sf "/usr/share/zoneinfo/$TIMEZONE" "$TARGET/etc/localtime"

# Root password
echo "root:$ROOT_PASS" | chroot "$TARGET" chpasswd

# Network (DHCP)
cat > "$TARGET/etc/rc.d/rc.inet1.conf" <<EOF
IPADDR[0]=""
NETMASK[0]=""
USE_DHCP[0]="yes"
DHCP_HOSTNAME[0]="$HOSTNAME"
EOF

#=============================================================================
# BOOTLOADER
#=============================================================================
mount --bind /dev "$TARGET/dev"
mount --bind /proc "$TARGET/proc"
mount --bind /sys "$TARGET/sys"

if [[ "$BOOT_MODE" == "uefi" ]]; then
    echo ">>> Installing ELILO (UEFI)..."
    
    # Install ELILO to EFI partition
    mkdir -p "$TARGET/boot/efi/EFI/Slackware"
    cp "$TARGET/usr/share/elilo"/*.efi "$TARGET/boot/efi/EFI/Slackware/" 2>/dev/null || \
        cp "$TARGET/boot/elilo"*.efi "$TARGET/boot/efi/EFI/Slackware/" 2>/dev/null || true
    
    # Find the kernel
    KERNEL=$(ls "$TARGET/boot/vmlinuz-"* 2>/dev/null | head -1 | xargs basename)
    if [[ -z "$KERNEL" ]]; then
        KERNEL="vmlinuz"
    fi
    
    cat > "$TARGET/boot/efi/EFI/Slackware/elilo.conf" <<EOF
timeout = 50
default = Linux

image = $KERNEL
    label = Linux
    root = $PART_ROOT
    read-only
EOF

    # Copy kernel to EFI partition
    cp "$TARGET/boot/$KERNEL" "$TARGET/boot/efi/EFI/Slackware/"
    
    # Register with EFI (if efibootmgr available)
    if command -v efibootmgr &>/dev/null; then
        # Get disk and partition number for EFI
        EFI_DISK="$TARGET_DISK"
        EFI_PART_NUM=1
        efibootmgr -c -d "$EFI_DISK" -p "$EFI_PART_NUM" \
            -l "\\EFI\\Slackware\\elilo.efi" -L "Slackware" 2>/dev/null || true
    fi
else
    echo ">>> Installing LILO (BIOS)..."
    
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

    chroot "$TARGET" /sbin/lilo
fi

umount "$TARGET/sys"
umount "$TARGET/proc"
umount "$TARGET/dev"

#=============================================================================
# CLEANUP
#=============================================================================
echo ">>> Cleaning up..."
swapoff "$PART_SWAP"
if [[ "$BOOT_MODE" == "uefi" ]]; then
    umount "$TARGET/boot/efi"
fi
umount "$TARGET"

echo ""
echo "=== GOSH SLACK INSTALLER COMPLETE ==="
echo "Boot mode:   $BOOT_MODE"
echo "Installed:   $TARGET_DISK"
echo ""
echo "Remove install media and reboot."
