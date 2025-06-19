<?php

  /* vmbackup plugin
     copyright JTok */

  require_once '/usr/local/emhttp/plugins/vmbackup/include/functions.php';
  require_once '/usr/local/emhttp/plugins/vmbackup/include/sanitization.php';
  require_once '/usr/local/emhttp/plugins/vmbackup/include/validation.php';

  $plugin = 'vmbackup';
  $plugin_path = '/boot/config/plugins/' . $plugin;

  if (isset($_POST['current_config_upload_scripts'])) {
    $current_config = $_POST['current_config_upload_scripts'];
  } else {
    $current_config = "default";
  }

  if (!strcasecmp($current_config, "default") == 0) {
    $plugin_configs_path = $plugin_path . '/configs';
    $current_config_path = $plugin_configs_path . '/' . $current_config;
    $pre_script_file = $current_config_path . '/pre-script.sh';
    $post_script_file = $current_config_path . '/post-script.sh';
  } else {
    $current_config_path = $plugin_path;
    $pre_script_file = $plugin_path . '/pre-script.sh';
    $post_script_file = $plugin_path . '/post-script.sh';
  }


  if (isset($_POST['save_pre_script'])) {
    if (!verify_dir($current_config_path)) {
      exit; 
    }
    $pre_script_contents = $_POST['pre_script_textarea'];

    file_put_contents($pre_script_file, $pre_script_contents);
  }
  
  if (isset($_POST['remove_pre_script'])) {
    if (is_file($pre_script_file)) {
      unlink($pre_script_file);
    }
  }

  if (isset($_POST['save_post_script'])) {
    if (!verify_dir($current_config_path)) {
      exit; 
    }
    $post_script_contents = $_POST['post_script_textarea'];
    file_put_contents($post_script_file, $post_script_contents);
  }

  if (isset($_POST['remove_post_script'])) {
    if (is_file($post_script_file)) {
      unlink($post_script_file);
    }
  }
  
  echo '<script>done();</script>';
?>
