# Gosh Slack Installer

Fully automated Slackware Linux installer. Boot the ISO, walk away, come back to a working system.

## Features

- **Zero interaction** - No prompts, no questions
- **Auto-detection** - Finds the right disk, avoids install media
- **BIOS & UEFI** - Works on both legacy and modern systems
- **NVMe support** - Handles all disk naming schemes
- **Configurable** - Override defaults via kernel parameters

## Quick Start

1. Download the latest ISO from [Releases](../../releases)
2. Write to USB: `dd if=gosh-slack-*.iso of=/dev/sdX bs=4M status=progress`
3. Boot the target machine from USB
4. Press Enter to start auto-install (default). If you see a `boot:` prompt, type `gosh` or `gosh-reboot`
5. Wait ~15-30 minutes
6. Remove USB and reboot

## Boot Menu Options

| Option | Description |
|--------|-------------|
| Gosh Slack Auto-Install | Standard install, manual reboot |
| Gosh Slack Auto-Install (Auto-Reboot) | Install + automatic reboot |

## Kernel Parameters

Customize the install by editing the boot command (press Tab at boot menu):

```
gosh_auto gosh_hostname=mybox gosh_timezone=America/New_York gosh_pass=secret123
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| `gosh_hostname=` | `slackbox` | System hostname |
| `gosh_timezone=` | `US/Pacific` | Timezone (from `/usr/share/zoneinfo`) |
| `gosh_pass=` | `changeme` | Root password |
| `gosh_reboot=` | `false` | Auto-reboot when done (`true`/`false`) |

## What Gets Installed

- Full Slackware installation (all package series: A, AP, D, E, F, K, KDE, L, N, T, TCL, X, XAP, XFCE, Y)
- DHCP networking enabled
- LILO (BIOS) or ELILO (UEFI) bootloader

## Disk Selection Logic

The installer automatically selects a target disk:

1. Finds all non-removable disks
2. Excludes the disk containing the install media
3. Selects the largest remaining disk
4. **⚠️ DESTROYS ALL DATA on selected disk**

## Partition Layout

**BIOS Systems (MBR):**
```
├─ Partition 1: / (ext4, bootable) - all space minus swap
└─ Partition 2: swap              - matches RAM (1-8GB cap)
```

**UEFI Systems (GPT):**
```
├─ Partition 1: /boot/efi (FAT32) - 512MB
├─ Partition 2: / (ext4)          - all space minus swap/EFI
└─ Partition 3: swap              - matches RAM (1-8GB cap)
```

## Building Locally

Requirements: Linux with `xorriso`, `cpio`, `squashfs-tools`, `curl`, `rsync`

```bash
git clone https://github.com/YOUR_USERNAME/gosh-slack-installer
cd gosh-slack-installer
sudo ./scripts/build-iso.sh
```

Output: `output/gosh-slack-15.0-64.iso`

### Build Options

To build a different version:

```bash
# Build Slackware 14.2 (32-bit) instead of default 15.0 (64-bit)
SLACK_VERSION=14.2 SLACK_ARCH=32 sudo -E ./scripts/build-iso.sh
```

## GitHub Actions

The repository includes automated builds:

- **Push to main**: Builds ISO, uploads as artifact
- **Tag with `v*`**: Creates GitHub Release with ISO

### Manual Trigger

Go to Actions → Build Gosh Slack ISO → Run workflow → Select version/arch

## Safety

- 5-second countdown before disk operations
- Excludes removable media from target selection
- Excludes the boot/install media from targets
- Clear boot menu warnings

**However**: This tool is designed to wipe disks automatically. Use with caution. Test in VMs first.

## Testing with QEMU

```bash
# Create test disk
qemu-img create -f qcow2 test-disk.qcow2 20G

# Boot ISO (BIOS)
qemu-system-x86_64 -m 2G -hda test-disk.qcow2 -cdrom gosh-slack-15.0-64.iso -boot d

# Boot ISO (UEFI) - requires OVMF
qemu-system-x86_64 -m 2G -hda test-disk.qcow2 -cdrom gosh-slack-15.0-64.iso \
    -bios /usr/share/OVMF/OVMF_CODE.fd -boot d
```

## License

AGPL-3.0-or-later

## Contributing

Issues and PRs welcome. Please test changes in a VM before submitting.
