# unraid.vmbackup (Community Fork)

> Fork of [JTok/unraid.vmbackup](https://github.com/JTok/unraid.vmbackup) — maintained by [Interstellar-code](https://github.com/Interstellar-code)

v0.3.0 - 2026/03/28

Plugin for backing up **and restoring** VMs in unRAID including vdisks, configuration files, and nvram.

## What's New in v0.3.0

- **Restore Tab** — restore VMs from backups directly from the WebGUI (supports all 3 backup formats: uncompressed, zstd, tar.gz)
- **Unraid 7 Compatibility** — fixes settings not saving on Unraid 7 (issues #46, #47)
- **13 Bug Fixes** — see [CHANGELOG.md](CHANGELOG.md) for full details
- **Rsyncable Compression** — optional `--rsyncable` flag for zstd/gzip for efficient remote sync

### Restore Feature

The new **Restore** tab (Settings → VM Backup → Restore) provides:

1. **Scan** your backup location to discover available VM backups and versions
2. **Select** which VMs to restore and from which backup version
3. **Dry Run** mode to preview what will happen without making changes
4. **Safety Net** — current files are renamed to `.pre_restore_tmp` before overwriting, and automatically reverted if you stop the restore mid-way
5. **Live Status** — real-time progress updates in the WebGUI
6. Supports all backup formats: uncompressed, zstd-compressed, and legacy tar.gz

## Installation

- Install via Community Applications (search "VM Backup")
- Or manually install from: `https://raw.githubusercontent.com/Interstellar-code/unraid.vmbackup/master/vmbackup.plg`
- Configure via Settings → User Utilities → VM Backup

## Features

### Backup

- Backup all VMs or a specific list; optionally use the list as an exclusion list
- Scheduled backups (daily, weekly, monthly, or custom cron)
- Retain backups by number or by age
- Snapshot-based backups to avoid shutting down running VMs (requires qemu guest agent)
- Zstandard inline compression (multi-threaded) or legacy gzip compression
- Pre-script and post-script support
- Per-config backup profiles with independent schedules
- Reconstruct write (turbo write) mode during backups
- Detailed notifications via the unRAID notification system
- Delta sync support (rsync-based incremental copies)

### Restore (NEW)

The Restore tab allows you to restore VMs from existing backups without any manual file operations:

- Scan your backup directory to list all available VMs and backup versions
- Select one or more VMs and choose which backup version to restore
- Dry Run mode — simulate the restore without changing any files
- Safety Net — originals are preserved in `.pre_restore_tmp` before being overwritten
- Stop in the middle — already-copied files are reverted automatically
- Supports uncompressed, zstd, and tar.gz backup formats

### Settings Tabs

| Tab | Description |
|-----|-------------|
| **Settings** | Core backup options: location, schedule, VM selection, compression |
| **Upload Scripts** | Paste pre/post shell scripts that run before/after the backup |
| **Other Settings** | Logging, notifications, and advanced tuning options |
| **Danger Zone** | Low-level options with potential side effects; read help before changing |
| **Manage Configs** | Create, rename, copy, and delete named backup configurations |
| **Restore** | Restore VMs from existing backups |

## Important Notes

Virtual disks attached to a single VM must have unique filenames regardless of their location. During the backup they are placed into the same folder, so two vdisks with the same name under the same VM will overwrite each other.

Example: VM1 cannot have both `/mnt/diskX/vdisk1.img` and `/mnt/user/domains/VM1/vdisk1.img`. However, VM1 and VM2 can both have a `vdisk1.img` since they back up to separate folders.

## Changelog

See [CHANGELOG.md](CHANGELOG.md)

## Credits

- Original plugin by [JTok](https://github.com/JTok/unraid.vmbackup)
- Community fork maintained by [Interstellar-code](https://github.com/Interstellar-code)
- Thanks to the Unraid community plugin developers, especially Squid, bonienl, dlandon, and dmacias

## License

MIT — see [LICENSE](Documentation/LICENSE)
