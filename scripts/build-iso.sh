#!/bin/bash
# Gosh Slack ISO Builder - Remaster Slackware ISO with auto-installer
# SPDX-License-Identifier: AGPL-3.0-or-later

set -euo pipefail

#=============================================================================
# CONFIGURATION
#=============================================================================
SLACK_VERSION="${SLACK_VERSION:-15.0}"
SLACK_ARCH="${SLACK_ARCH:-64}"
WORK_DIR="${WORK_DIR:-/tmp/gosh-slack-build}"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/output}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Slackware mirror
MIRROR="https://mirrors.slackware.com/slackware/slackware-iso"
if [[ "$SLACK_ARCH" == "64" ]]; then
    ISO_NAME="slackware64-${SLACK_VERSION}-install-dvd.iso"
    ISO_URL="${MIRROR}/slackware64-${SLACK_VERSION}-iso/${ISO_NAME}"
else
    ISO_NAME="slackware-${SLACK_VERSION}-install-dvd.iso"
    ISO_URL="${MIRROR}/slackware-${SLACK_VERSION}-iso/${ISO_NAME}"
fi

#=============================================================================
# SETUP
#=============================================================================
mkdir -p "$WORK_DIR" "$OUTPUT_DIR"

ORIG_ISO="$WORK_DIR/$ISO_NAME"
ISO_MOUNT="$WORK_DIR/iso-mount"
ISO_WORK="$WORK_DIR/iso-work"
INITRD_WORK="$WORK_DIR/initrd-work"

#=============================================================================
# DOWNLOAD ISO
#=============================================================================
if [[ ! -f "$ORIG_ISO" ]]; then
    echo ">>> Downloading Slackware ISO from $ISO_URL..."
    curl -fL --progress-bar -o "$ORIG_ISO" "$ISO_URL"
fi

# Verify we got an actual ISO (should be at least 1GB)
ISO_SIZE=$(stat -c%s "$ORIG_ISO" 2>/dev/null || stat -f%z "$ORIG_ISO" 2>/dev/null)
if [[ "$ISO_SIZE" -lt 1000000000 ]]; then
    echo "Error: Downloaded file is too small (${ISO_SIZE} bytes). Expected ISO to be > 1GB" >&2
    echo "The mirror may be down or the URL may be incorrect." >&2
    rm -f "$ORIG_ISO"
    exit 1
fi
echo ">>> ISO verified: $(numfmt --to=iec-i --suffix=B "$ISO_SIZE" 2>/dev/null || echo "${ISO_SIZE} bytes")"

#=============================================================================
# EXTRACT ISO
#=============================================================================
echo ">>> Extracting ISO..."
mkdir -p "$ISO_MOUNT" "$ISO_WORK"
mount -o loop,ro "$ORIG_ISO" "$ISO_MOUNT"
rsync -a "$ISO_MOUNT/" "$ISO_WORK/"
umount "$ISO_MOUNT"

#=============================================================================
# INJECT INSTALLER SCRIPT
#=============================================================================
echo ">>> Injecting gosh-slack-installer..."
cp "$SCRIPT_DIR/gosh-slack-installer.sh" "$ISO_WORK/"
chmod +x "$ISO_WORK/gosh-slack-installer.sh"

#=============================================================================
# MODIFY INITRD TO AUTO-RUN INSTALLER
#=============================================================================
echo ">>> Modifying initrd to auto-run installer..."
mkdir -p "$INITRD_WORK"
cd "$INITRD_WORK"

# Detect initrd compression format and extract
INITRD_FILE="$ISO_WORK/isolinux/initrd.img"
INITRD_FORMAT=$(file "$INITRD_FILE" | head -1)
echo ">>> Initrd format: $INITRD_FORMAT"

if echo "$INITRD_FORMAT" | grep -q "gzip"; then
    gzip -dc "$INITRD_FILE" | cpio -idm 2>/dev/null
    INITRD_COMPRESS="gzip -9"
elif echo "$INITRD_FORMAT" | grep -q "XZ"; then
    xz -dc "$INITRD_FILE" | cpio -idm 2>/dev/null
    INITRD_COMPRESS="xz --check=crc32"
elif echo "$INITRD_FORMAT" | grep -q "LZMA"; then
    lzma -dc "$INITRD_FILE" | cpio -idm 2>/dev/null
    INITRD_COMPRESS="lzma"
elif echo "$INITRD_FORMAT" | grep -q "LZ4"; then
    lz4 -dc "$INITRD_FILE" | cpio -idm 2>/dev/null
    INITRD_COMPRESS="lz4 -l"
elif echo "$INITRD_FORMAT" | grep -q "Zstandard"; then
    zstd -dc "$INITRD_FILE" | cpio -idm 2>/dev/null
    INITRD_COMPRESS="zstd"
elif echo "$INITRD_FORMAT" | grep -q "cpio"; then
    # Uncompressed cpio
    cpio -idm < "$INITRD_FILE" 2>/dev/null
    INITRD_COMPRESS="cat"
else
    echo "ERROR: Unknown initrd format: $INITRD_FORMAT" >&2
    exit 1
fi

# Copy installer script into initrd
cp "$SCRIPT_DIR/gosh-slack-installer.sh" "$INITRD_WORK/usr/bin/gosh-slack-installer"
chmod +x "$INITRD_WORK/usr/bin/gosh-slack-installer"

# Create auto-run hook that checks for gosh_auto kernel parameter
cat > "$INITRD_WORK/etc/rc.d/rc.gosh" <<'GOSH_HOOK'
#!/bin/bash
# Gosh Slack Auto-Installer Hook
# Checks for gosh_auto kernel parameter and runs installer

if grep -q "gosh_auto" /proc/cmdline; then
    echo ""
    echo "=========================================="
    echo "  GOSH SLACK AUTO-INSTALLER DETECTED"
    echo "=========================================="
    echo ""

    # Wait for devices to settle
    sleep 3

    # Mount the CD-ROM to access packages
    mkdir -p /mnt/cdrom
    for dev in /dev/sr0 /dev/cdrom /dev/hdc; do
        if [[ -b "$dev" ]]; then
            mount -o ro "$dev" /mnt/cdrom 2>/dev/null && break
        fi
    done

    # Check if we found the Slackware source
    if [[ -d /mnt/cdrom/slackware64 ]]; then
        export SLACK_SOURCE="/mnt/cdrom/slackware64"
    elif [[ -d /mnt/cdrom/slackware ]]; then
        export SLACK_SOURCE="/mnt/cdrom/slackware"
    else
        echo "ERROR: Could not find Slackware packages on CD-ROM"
        exec /bin/bash
    fi

    # Parse kernel parameters for customization
    for param in $(cat /proc/cmdline); do
        case "$param" in
            gosh_hostname=*) export HOSTNAME="${param#*=}" ;;
            gosh_timezone=*) export TIMEZONE="${param#*=}" ;;
            gosh_pass=*)     export ROOT_PASS="${param#*=}" ;;
            gosh_reboot=*)   export AUTO_REBOOT="${param#*=}" ;;
        esac
    done

    # Run the installer
    /usr/bin/gosh-slack-installer

    # Handle reboot
    if [[ "$AUTO_REBOOT" == "true" ]]; then
        echo ">>> Auto-rebooting in 10 seconds..."
        sleep 10
        reboot -f
    else
        echo ""
        echo "Installation complete. Remove install media and reboot."
        echo "Or type 'reboot' to restart now."
        exec /bin/bash
    fi
fi
GOSH_HOOK
chmod +x "$INITRD_WORK/etc/rc.d/rc.gosh"

# Hook into rc.S to run our script (add before the shell prompt)
if [[ -f "$INITRD_WORK/etc/rc.d/rc.S" ]]; then
    # Add hook near the end of rc.S, before it drops to shell
    sed -i '/# Start a shell/i \
# Gosh Slack Auto-Installer hook\n/etc/rc.d/rc.gosh\n' "$INITRD_WORK/etc/rc.d/rc.S"
fi

# Repack initrd with same compression format
echo ">>> Repacking initrd with: $INITRD_COMPRESS"
find . | cpio -o -H newc 2>/dev/null | $INITRD_COMPRESS > "$ISO_WORK/isolinux/initrd.img"
cd "$WORK_DIR"

#=============================================================================
# ADD BOOT MENU ENTRIES
#=============================================================================
echo ">>> Adding boot menu entries..."

# Add custom boot entry to isolinux
if [[ -f "$ISO_WORK/isolinux/isolinux.cfg" ]]; then
    cat >> "$ISO_WORK/isolinux/isolinux.cfg" <<'EOF'

LABEL gosh
  MENU LABEL ^Gosh Slack Auto-Install
  KERNEL /kernels/huge.s/bzImage
  APPEND initrd=/isolinux/initrd.img load_ramdisk=1 prompt_ramdisk=0 rw SLACK_KERNEL=huge.s gosh_auto=1

LABEL gosh-reboot
  MENU LABEL Gosh Slack Auto-Install (^Auto-Reboot)
  KERNEL /kernels/huge.s/bzImage
  APPEND initrd=/isolinux/initrd.img load_ramdisk=1 prompt_ramdisk=0 rw SLACK_KERNEL=huge.s gosh_auto=1 gosh_reboot=true
EOF
fi

# Add to EFI boot if present
if [[ -f "$ISO_WORK/EFI/BOOT/grub.cfg" ]]; then
    cat >> "$ISO_WORK/EFI/BOOT/grub.cfg" <<'EOF'

menuentry "Gosh Slack Auto-Install" {
    linux /kernels/huge.s/bzImage load_ramdisk=1 prompt_ramdisk=0 rw SLACK_KERNEL=huge.s gosh_auto=1
    initrd /isolinux/initrd.img
}

menuentry "Gosh Slack Auto-Install (Auto-Reboot)" {
    linux /kernels/huge.s/bzImage load_ramdisk=1 prompt_ramdisk=0 rw SLACK_KERNEL=huge.s gosh_auto=1 gosh_reboot=true
    initrd /isolinux/initrd.img
}
EOF
fi

#=============================================================================
# REBUILD ISO
#=============================================================================
echo ">>> Building new ISO..."
OUTPUT_ISO="$OUTPUT_DIR/gosh-slack-${SLACK_VERSION}-${SLACK_ARCH}.iso"

xorriso -as mkisofs \
    -o "$OUTPUT_ISO" \
    -R -J -joliet-long \
    -V "GoshSlack_${SLACK_VERSION}" \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    -eltorito-alt-boot \
    -e isolinux/efiboot.img \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    "$ISO_WORK"

#=============================================================================
# CLEANUP
#=============================================================================
echo ">>> Cleaning up..."
rm -rf "$ISO_MOUNT" "$ISO_WORK" "$INITRD_WORK"

echo ""
echo "=== BUILD COMPLETE ==="
echo "Output: $OUTPUT_ISO"
echo "Size: $(du -h "$OUTPUT_ISO" | cut -f1)"
