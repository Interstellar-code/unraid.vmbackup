<?php
// vmbackup restore functions

/**
 * Scan backup location and return structured version data for all VMs.
 * Groups files by timestamp prefix, checks completeness.
 *
 * @param string $backup_location Path to backup root
 * @return array ['vm_name' => ['timestamp' => ['format'=>..., 'has_xml'=>bool, 'has_nvram'=>bool, 'disk_count'=>int, 'complete'=>bool]]]
 */
function scan_backup_versions($backup_location) {
  $vms = [];
  if (!is_dir($backup_location)) return $vms;

  // Each subdirectory is a VM name
  foreach (glob($backup_location . '/*', GLOB_ONLYDIR) as $vm_dir) {
    $vm_name = basename($vm_dir);
    if ($vm_name === 'logs') continue; // skip logs folder

    $versions = [];
    $files = scandir($vm_dir);

    // Group files by timestamp prefix
    // Supports YYYYMMDD_HHMM_ (JTok 4-digit) and YYYYMMDD_HHMMSS_ (6-digit)
    $grouped = [];
    foreach ($files as $f) {
      if ($f === '.' || $f === '..') continue;
      if (preg_match('/^(\d{8}_\d{4,6})_/', $f, $m)) {
        $ts = $m[1];
        $grouped[$ts][] = $f;
      }
    }

    // Also check for non-timestamped files (single backup mode)
    $non_ts_files = [];
    foreach ($files as $f) {
      if ($f === '.' || $f === '..') continue;
      if (!preg_match('/^\d{8}_/', $f)) {
        $non_ts_files[] = $f;
      }
    }
    if (!empty($non_ts_files)) {
      // Check if these look like backup files
      $has_any_xml = false;
      $has_any_disk = false;
      foreach ($non_ts_files as $f) {
        $ext = pathinfo($f, PATHINFO_EXTENSION);
        if ($ext === 'xml') $has_any_xml = true;
        if (in_array($ext, ['img', 'qcow2', 'raw', 'zst', 'gz'])) $has_any_disk = true;
      }
      if ($has_any_xml || $has_any_disk) {
        $grouped['no_timestamp'] = $non_ts_files;
      }
    }

    foreach ($grouped as $ts => $group_files) {
      $has_xml = false;
      $has_nvram = false;
      $disk_count = 0;
      $format = 'uncompressed';

      foreach ($group_files as $f) {
        $ext = pathinfo($f, PATHINFO_EXTENSION);
        if ($ext === 'xml') $has_xml = true;
        elseif ($ext === 'fd') $has_nvram = true;
        elseif ($ext === 'zst') { $disk_count++; $format = 'zstd'; }
        elseif ($ext === 'gz' && str_ends_with($f, '.tar.gz')) { $format = 'tar_gz'; $disk_count++; }
        elseif (in_array($ext, ['img', 'qcow2', 'raw', 'vhdx', 'vmdk'])) $disk_count++;
      }

      $versions[$ts] = [
        'timestamp' => $ts,
        'display' => format_timestamp_display($ts),
        'format' => $format,
        'has_xml' => $has_xml,
        'has_nvram' => $has_nvram,
        'disk_count' => $disk_count,
        'complete' => $has_xml && $disk_count > 0,
        'files' => $group_files,
      ];
    }

    // Sort versions newest-first
    krsort($versions);
    if (!empty($versions)) {
      $vms[$vm_name] = array_values($versions);
    }
  }
  ksort($vms);
  return $vms;
}

/**
 * Format a timestamp string for display
 */
function format_timestamp_display($ts) {
  if ($ts === 'no_timestamp') return 'No timestamp (single backup)';
  // YYYYMMDD_HHMM or YYYYMMDD_HHMMSS
  if (preg_match('/^(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})?$/', $ts, $m)) {
    $date = "{$m[1]}-{$m[2]}-{$m[3]}";
    $time = "{$m[4]}:{$m[5]}";
    if (!empty($m[6])) $time .= ":{$m[6]}";
    return "{$date} {$time}";
  }
  return $ts;
}

/**
 * Write restore configuration file
 */
function write_restore_config($vm_selections, $backup_location, $dry_run) {
  $cfg_path = '/boot/config/plugins/vmbackup/restore.cfg';
  $contents = "; vmbackup restore config\n";
  $contents .= "backup_location=\"" . addslashes($backup_location) . "\"\n";
  $contents .= "restore_vms='" . json_encode($vm_selections) . "'\n";
  $contents .= "dry_run=\"" . ($dry_run ? '1' : '0') . "\"\n";

  $tmp = $cfg_path . '.tmp';
  file_put_contents($tmp, $contents);
  rename($tmp, $cfg_path);
}

/**
 * Check if backup or restore is currently running
 * @return array ['locked' => bool, 'type' => 'backup'|'restore'|null]
 */
function restore_lock_check() {
  // Check for restore PID
  $restore_pid_file = '/tmp/vmbackup/restore.pid';
  if (file_exists($restore_pid_file)) {
    $pid = (int)trim(file_get_contents($restore_pid_file));
    if ($pid > 0 && file_exists("/proc/{$pid}")) {
      return ['locked' => true, 'type' => 'restore'];
    }
    // Stale PID file
    @unlink($restore_pid_file);
  }

  // Check for backup PID files
  $backup_pids = glob('/tmp/vmbackup/scripts/*.pid');
  if ($backup_pids) {
    foreach ($backup_pids as $pid_file) {
      $pid = (int)trim(file_get_contents($pid_file));
      if ($pid > 0 && file_exists("/proc/{$pid}")) {
        return ['locked' => true, 'type' => 'backup'];
      }
    }
  }

  return ['locked' => false, 'type' => null];
}

/**
 * Get current restore status lines
 */
function get_restore_status() {
  $status_file = '/tmp/vmbackup/restore/restore-status.txt';
  if (!file_exists($status_file)) return [];
  $lines = file($status_file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
  return $lines ?: [];
}

/**
 * Get the restore log content
 */
function get_restore_log($tail_lines = 100) {
  $log_file = '/tmp/vmbackup/restore/restore.log';
  if (!file_exists($log_file)) return '';
  $lines = file($log_file);
  if ($lines === false) return '';
  $lines = array_slice($lines, -$tail_lines);
  return implode('', $lines);
}
