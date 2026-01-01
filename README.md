# Gosh Slack Installer

A dead-simple, fully automated Slackware installer. Boot the install media, run one command, and 20 minutes later you have a working Slackware system.

## Features

- **Fully automatic** — auto-detects target disk, calculates partition sizes
- **No prompts** — just a 5-second abort window
- **Smart partitioning** — swap sized to RAM (1-8GB cap), root gets the rest
- **Full install** — all package series included
- **DHCP networking** — ready to connect on first boot

## Requirements

- Slackware 15.0+ install media (USB/DVD)
- Target system with at least 8GB disk
- BIOS/MBR boot (not UEFI)

## Usage

### One-liner from GitHub

Boot the Slackware install media, then:

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/gosh-slack-installer/main/gosh-slack-installer.sh | bash
```

Or if you want to inspect before running:

```bash
curl -fsSLO https://raw.githubusercontent.com/YOUR_USERNAME/gosh-slack-installer/main/gosh-slack-installer.sh
less gosh-slack-installer.sh
bash gosh-slack-installer.sh
```

### From local copy

```bash
chmod +x gosh-slack-installer.sh
./gosh-slack-installer.sh
```

## Configuration

Edit the top of the script to change defaults:

| Variable | Default | Description |
|----------|---------|-------------|
| `HOSTNAME` | `slackbox` | System hostname |
| `TIMEZONE` | `US/Pacific` | Timezone |
| `ROOT_PASS` | `changeme` | Root password |
| `SLACK_SOURCE` | `/mnt/cdrom/slackware64` | Path to package source |

## What it does

1. Auto-detects the largest non-removable disk (excludes install media)
2. Wipes and partitions the disk (root + swap)
3. Formats partitions (ext4 + swap)
4. Installs all Slackware packages
5. Configures fstab, hostname, timezone, networking (DHCP)
6. Sets root password
7. Installs LILO bootloader
8. Cleans up and prompts for reboot

## After install

Default root password is `changeme` — change it on first login.

## License

AGPL-3.0-or-later

## Contributing

Issues and PRs welcome.
