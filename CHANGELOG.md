# Changelog

## v0.3.1 - 2026/03/29

### Fixes
- **Regex compatibility** — escape hyphens in character classes (`[\w.-]` → `[\w.\-]`) to fix `Invalid regular expression` errors in modern browsers using Unicode Sets mode
- **Package ownership** — build `.txz` with `root:root` ownership to prevent `/` directory ownership change on install (was breaking SSH key auth)

### Improvements
- **Backup status indicator** — Settings tab now shows an orange banner when a backup is running, with the config name and a "Stop Backup" button
- **Auto-disable Backup Now** — the button is disabled while a backup is already in progress
- **Stale PID cleanup** — automatically removes PID files for processes that are no longer running

## v0.3.0 - 2026/03/28

Community fork by [Interstellar-code](https://github.com/Interstellar-code/unraid.vmbackup), based on [JTok/unraid.vmbackup](https://github.com/JTok/unraid.vmbackup) v0.2.9.

### New Features

- **Restore Tab** — new WebGUI tab for restoring VMs from backups (#31)
  - Scan backup locations to discover VMs and backup versions
  - Select multiple VMs and specific versions to restore
  - Supports all 3 backup formats: uncompressed, zstd, and legacy tar.gz
  - Dry run mode to preview restore without making changes
  - Safety backup of current files (`.pre_restore_tmp`) before overwriting
  - Stop and revert — cancel mid-restore and files are automatically reverted
  - Real-time status updates in the WebGUI
  - SweetAlert confirmation dialog before restore
  - Lock file prevents concurrent backup and restore operations

- **Rsyncable Compression** — new toggle options for `--rsyncable` flag on zstd and gzip compression (#37)

### Bug Fixes

- **Unraid 7 Compatibility** — replace `#arg[N]` bracket notation with flat `#argN` names across all JS, page files, and PHP (#46, #47)
- **Double VM Resume** — re-check VM state between `set_vm_to_original_state` and `start_vm_after_backup` blocks to prevent "domain is already running" error (#52)
- **Inverted Snapshot Fallback** — correct log messages to match actual behavior: 0=disabled, 1=enabled (#29)
- **Block Device Passthrough** — skip `type='block'` disks from backup and snapshot operations (#28)
- **ISO Mount Crash** — skip `device='cdrom'` and `device='floppy'` disks to prevent `bad array subscript` error (#26)
- **Windows Quiesce Failure** — retry snapshot without `--quiesce` flag before falling back to standard backup (#30)
- **Shutdown Hang** — wrap critical `virsh` calls with `timeout 30` to prevent indefinite hangs (#18)
- **Snap Extension Collision** — improved error message suggesting "Fix Snapshots" from Danger Zone tab (#33)
- **VM Name Substring Match** — use exact matching instead of substring matching for VM selection lists (#32)
- **False Lock Warning** — lower lock-contention notification from `warning` to `normal` level (#34)
- **Unassigned Disk Paths** — allow `/mnt/disks/` and other `/mnt/` subpaths for backup location (#19)

### Security

- Path traversal validation on restore backup location (must be under `/mnt/`)

## v0.2.9 - 2024/05/02

Original release by JTok. See [original repository](https://github.com/JTok/unraid.vmbackup) for prior history.
