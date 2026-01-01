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

# Slackware mirror (use direct mirror, not the redirector)
MIRROR="https://slackware.osuosl.org"
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
# MODIFY INITRD TO AUTO-RUN INSTALLER (optional boot menu entry)
#=============================================================================
echo ">>> Modifying boot configuration..."

# Add custom boot entry to isolinux
if [[ -f "$ISO_WORK/isolinux/isolinux.cfg" ]]; then
    cat >> "$ISO_WORK/isolinux/isolinux.cfg" <<'EOF'

LABEL gosh
  MENU LABEL Gosh Slack Auto-Install
  KERNEL /kernels/huge.s/bzImage
  APPEND initrd=/isolinux/initrd.img load_ramdisk=1 prompt_ramdisk=0 rw SLACK_KERNEL=huge.s gosh_auto=1

LABEL gosh-custom
  MENU LABEL Gosh Slack Auto-Install (Custom)
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

menuentry "Gosh Slack Auto-Install (Custom)" {
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
