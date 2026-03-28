<?php
require_once '/usr/local/emhttp/plugins/vmbackup/include/restore_functions.php';

// Get CSRF token for validation
$csrf_token = $_POST['csrf_token'] ?? $_GET['csrf_token'] ?? '';
$action = $_POST['action'] ?? $_GET['action'] ?? '';

header('Content-Type: application/json');

switch ($action) {
  case 'scan':
    $backup_location = $_POST['backup_location'] ?? '';
    if (empty($backup_location) || !is_dir($backup_location)) {
      echo json_encode(['error' => 'Invalid or missing backup location']);
      exit;
    }
    $real_path = realpath($backup_location);
    if ($real_path === false || strpos($real_path, '/mnt/') !== 0) {
      echo json_encode(['error' => 'Backup location must be under /mnt/']);
      exit;
    }
    $backup_location = $real_path;
    $versions = scan_backup_versions($backup_location);
    echo json_encode(['success' => true, 'vms' => $versions]);
    break;

  case 'restore_now':
    $lock = restore_lock_check();
    if ($lock['locked']) {
      echo json_encode(['error' => "Cannot start restore: a {$lock['type']} operation is already running"]);
      exit;
    }

    $backup_location = $_POST['backup_location'] ?? '';
    $vm_selections = $_POST['vm_selections'] ?? '[]';
    $dry_run = ($_POST['dry_run'] ?? '0') === '1';

    if (empty($backup_location) || !is_dir($backup_location)) {
      echo json_encode(['error' => 'Invalid backup location']);
      exit;
    }
    $real_path = realpath($backup_location);
    if ($real_path === false || strpos($real_path, '/mnt/') !== 0) {
      echo json_encode(['error' => 'Backup location must be under /mnt/']);
      exit;
    }
    $backup_location = $real_path;

    $selections = json_decode($vm_selections, true);
    if (empty($selections)) {
      echo json_encode(['error' => 'No VMs selected for restore']);
      exit;
    }

    // Write restore config
    write_restore_config($selections, $backup_location, $dry_run);

    // Clear old status
    @mkdir('/tmp/vmbackup/restore', 0777, true);
    @unlink('/tmp/vmbackup/restore/restore-status.txt');
    @unlink('/tmp/vmbackup/restore/restore-stop.txt');

    // Launch restore script
    $restore_script = '/usr/local/emhttp/plugins/vmbackup/scripts/restore.sh';
    exec("nohup bash {$restore_script} > /dev/null 2>&1 &");

    // Brief wait for PID file
    usleep(500000);

    echo json_encode(['success' => true, 'message' => 'Restore started']);
    break;

  case 'stop_restore':
    $stop_file = '/tmp/vmbackup/restore/restore-stop.txt';
    @mkdir('/tmp/vmbackup/restore', 0777, true);
    file_put_contents($stop_file, date('Y-m-d H:i:s'));

    // Also send SIGTERM to restore process
    $pid_file = '/tmp/vmbackup/restore.pid';
    if (file_exists($pid_file)) {
      $pid = (int)trim(file_get_contents($pid_file));
      if ($pid > 0) {
        exec("kill -TERM {$pid} 2>/dev/null");
      }
    }
    echo json_encode(['success' => true, 'message' => 'Stop signal sent']);
    break;

  case 'get_status':
    $status_lines = get_restore_status();
    $lock = restore_lock_check();
    $is_running = ($lock['locked'] && $lock['type'] === 'restore');
    $log = get_restore_log(50);
    echo json_encode([
      'running' => $is_running,
      'status' => $status_lines,
      'log' => $log,
    ]);
    break;

  default:
    echo json_encode(['error' => 'Unknown action']);
    break;
}
