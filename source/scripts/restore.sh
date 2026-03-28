#!/bin/bash
# shellcheck enable=require-variable-braces
# vmbackup restore script
# Reads restore configuration from /boot/config/plugins/vmbackup/restore.cfg

################################################## constants start ###############################################################

PLUGIN_PATH="/usr/local/emhttp/plugins/vmbackup"
PLUGIN_TMP="/tmp/vmbackup"
RESTORE_TMP="${PLUGIN_TMP}/restore"
STATUS_FILE="${RESTORE_TMP}/restore-status.txt"
STOP_FILE="${RESTORE_TMP}/restore-stop.txt"
PID_FILE="${PLUGIN_TMP}/restore.pid"
RESTORE_CFG="/boot/config/plugins/vmbackup/restore.cfg"
LOG_FILE="${RESTORE_TMP}/restore.log"
VIRSH_TIMEOUT=30

################################################## constants end #################################################################


################################################## global state start ###########################################################

# track files that were renamed as pre_restore safety backups so the cleanup trap can revert them on stop
declare -a PRE_RESTORE_TMP_FILES=()

# overall error tracking
RESTORE_ERRORS=0

################################################## global state end #############################################################


################################################## functions start ##############################################################

log_message() {
  local level="${1:-INFO}"
  local message="${2:-}"
  echo "$(date '+%Y-%m-%d %H:%M:%S') [${level}] ${message}"
}

update_status() {
  local vm="${1}"
  local state="${2}"
  local message="${3:-}"
  echo "$(date '+%Y-%m-%d %H:%M:%S')|${vm}|${state}|${message}" >> "${STATUS_FILE}"
}

cleanup() {
  log_message "INFO" "Running cleanup..."

  # If stop was requested, revert any safety-backup renames
  if [[ -f "${STOP_FILE}" ]]; then
    log_message "WARN" "Restore stopped via stop file. Reverting pre-restore temporary files..."
    for pre_tmp in "${PRE_RESTORE_TMP_FILES[@]}"; do
      local original="${pre_tmp%.pre_restore_tmp}"
      if [[ -f "${pre_tmp}" ]]; then
        if mv "${pre_tmp}" "${original}"; then
          log_message "INFO" "Reverted: ${pre_tmp} -> ${original}"
        else
          log_message "ERROR" "Failed to revert: ${pre_tmp} -> ${original}"
        fi
      fi
    done
    log_message "INFO" "Restore stopped, files reverted."
  fi

  # Always remove PID file and stop file
  [[ -f "${PID_FILE}" ]] && rm -f "${PID_FILE}"
  [[ -f "${STOP_FILE}" ]] && rm -f "${STOP_FILE}"
}

copy_with_fallback() {
  local src="${1}"
  local dst="${2}"

  mkdir -p "$(dirname "${dst}")"

  if [[ "${dry_run}" == "1" ]]; then
    log_message "DRY-RUN" "Would copy: ${src} -> ${dst}"
    return 0
  fi

  # Try reflink (instant on CoW filesystems like Btrfs/XFS)
  if cp --reflink=always "${src}" "${dst}" 2>/dev/null; then
    log_message "INFO" "Copied (reflink): ${src} -> ${dst}"
    return 0
  fi

  # Try sparse copy
  if cp --sparse=always "${src}" "${dst}" 2>/dev/null; then
    log_message "INFO" "Copied (sparse): ${src} -> ${dst}"
    return 0
  fi

  # Fallback to rsync sparse
  if rsync --sparse "${src}" "${dst}"; then
    log_message "INFO" "Copied (rsync sparse): ${src} -> ${dst}"
    return 0
  fi

  log_message "ERROR" "All copy methods failed for: ${src} -> ${dst}"
  return 1
}

# Parse restore_vms JSON and emit lines: vm<TAB>version
parse_restore_vms() {
  local json="${1}"

  # Try python3 first
  if command -v python3 &>/dev/null; then
    python3 - "${json}" <<'PYEOF'
import sys, json
try:
    data = json.loads(sys.argv[1])
    for entry in data:
        vm = entry.get("vm", "")
        version = entry.get("version", "")
        if vm:
            print(f"{vm}\t{version}")
except Exception as e:
    sys.exit(1)
PYEOF
    return $?
  fi

  # Try jq
  if command -v jq &>/dev/null; then
    echo "${json}" | jq -r '.[] | "\(.vm)\t\(.version)"'
    return $?
  fi

  # Fallback: basic sed/grep parsing for simple JSON arrays
  # Handles: [{"vm":"Name","version":"YYYYMMDD_HHMM"}, ...]
  echo "${json}" | grep -oP '\{[^}]+\}' | while IFS= read -r obj; do
    local vm version
    vm=$(echo "${obj}" | grep -oP '"vm"\s*:\s*"\K[^"]+')
    version=$(echo "${obj}" | grep -oP '"version"\s*:\s*"\K[^"]+')
    if [[ -n "${vm}" ]]; then
      printf '%s\t%s\n' "${vm}" "${version}"
    fi
  done
}

# Get disk source paths from a libvirt XML file
get_disk_paths_from_xml() {
  local xml_file="${1}"

  if command -v xmllint &>/dev/null; then
    xmllint --xpath '//disk[@device="disk"]/source/@file' "${xml_file}" 2>/dev/null \
      | sed 's/file="//g; s/"//g; s/ /\n/g' \
      | grep -v '^$'
  else
    # Fallback grep-based extraction
    grep -oP 'source file="\K[^"]+' "${xml_file}" 2>/dev/null || true
  fi
}

# Get NVRAM path from a libvirt XML file
get_nvram_path_from_xml() {
  local xml_file="${1}"

  if command -v xmllint &>/dev/null; then
    xmllint --xpath 'string(//os/nvram)' "${xml_file}" 2>/dev/null
  else
    grep -oP '<nvram>\K[^<]+' "${xml_file}" 2>/dev/null | head -1 || true
  fi
}

# Shutdown a running VM and wait for it to stop
shutdown_vm() {
  local vm="${1}"

  local state
  state=$(timeout "${VIRSH_TIMEOUT}" virsh domstate "${vm}" 2>/dev/null || echo "unknown")

  case "${state}" in
    running|paused)
      log_message "INFO" "Shutting down VM: ${vm} (current state: ${state})"

      if [[ "${dry_run}" == "1" ]]; then
        log_message "DRY-RUN" "Would shut down VM: ${vm}"
        return 0
      fi

      timeout "${VIRSH_TIMEOUT}" virsh shutdown "${vm}" 2>/dev/null || true

      # Poll up to 5 minutes (30 checks × 10s)
      local checks=0
      while [[ ${checks} -lt 30 ]]; do
        sleep 10
        state=$(timeout "${VIRSH_TIMEOUT}" virsh domstate "${vm}" 2>/dev/null || echo "unknown")
        if [[ "${state}" == "shut off" ]]; then
          log_message "INFO" "VM shut down cleanly: ${vm}"
          return 0
        fi
        (( checks++ )) || true
        log_message "INFO" "Waiting for VM to shut down (${checks}/30): ${vm} — state: ${state}"
      done

      # Force destroy if it wouldn't shut down
      log_message "WARN" "VM did not shut down cleanly; forcing destroy: ${vm}"
      timeout "${VIRSH_TIMEOUT}" virsh destroy "${vm}" 2>/dev/null || true
      sleep 2
      ;;
    "shut off")
      log_message "INFO" "VM is already shut off: ${vm}"
      ;;
    *)
      log_message "WARN" "Unknown VM state '${state}' for: ${vm}; proceeding anyway"
      ;;
  esac
}

# Check whether a VM is currently defined in libvirt
vm_is_defined() {
  local vm="${1}"
  timeout "${VIRSH_TIMEOUT}" virsh dominfo "${vm}" &>/dev/null
}

restore_vm() {
  local vm="${1}"
  local version="${2}"

  log_message "INFO" "=========================================="
  log_message "INFO" "Starting restore for VM: ${vm}"
  [[ -n "${version}" ]] && log_message "INFO" "Version prefix: ${version}"
  update_status "${vm}" "started" "Beginning restore"

  # ---- Validate backup directory ----
  local vm_backup_dir="${backup_location}/${vm}"
  if [[ ! -d "${vm_backup_dir}" ]]; then
    log_message "ERROR" "Backup directory not found: ${vm_backup_dir}"
    update_status "${vm}" "error" "Backup directory not found: ${vm_backup_dir}"
    (( RESTORE_ERRORS++ )) || true
    return 1
  fi

  # ---- Build file prefix ----
  local prefix="${version:+${version}_}"

  # ---- Detect backup format ----
  local format="uncompressed"
  local tarball=""

  # Check for tar.gz bundle first
  tarball=$(find "${vm_backup_dir}" -maxdepth 1 -name "${prefix}${vm}.tar.gz" 2>/dev/null | sort | tail -1)
  if [[ -n "${tarball}" ]]; then
    format="targz"
    log_message "INFO" "Detected tar.gz format: ${tarball}"
  else
    # Check if any .zst files exist for this version
    local zst_count
    zst_count=$(find "${vm_backup_dir}" -maxdepth 1 -name "${prefix}*.zst" 2>/dev/null | wc -l)
    if [[ "${zst_count}" -gt 0 ]]; then
      format="zstd"
      log_message "INFO" "Detected zstd compressed format (${zst_count} .zst files)"
    else
      log_message "INFO" "Detected uncompressed format"
    fi
  fi

  # Verify at least some files exist for this version
  local backup_xml=""
  backup_xml=$(find "${vm_backup_dir}" -maxdepth 1 -name "${prefix}*.xml" 2>/dev/null | sort | tail -1)

  if [[ "${format}" != "targz" && -z "${backup_xml}" ]]; then
    log_message "ERROR" "No backup XML found in ${vm_backup_dir} with prefix '${prefix}'"
    update_status "${vm}" "error" "No backup files found"
    (( RESTORE_ERRORS++ )) || true
    return 1
  fi

  # ---- Check stop flag ----
  if [[ -f "${STOP_FILE}" ]]; then
    log_message "WARN" "Stop file detected. Aborting restore for: ${vm}"
    update_status "${vm}" "stopped" "Restore aborted by stop request"
    return 1
  fi

  # ---- Shutdown VM if running ----
  shutdown_vm "${vm}"

  # ---- Determine destination paths from backup XML ----
  local xml_dest="/etc/libvirt/qemu/${vm}.xml"
  local disk_paths=()
  local nvram_src_path=""
  local nvram_dest_path=""

  if [[ "${format}" == "targz" ]]; then
    # Extract to temp dir first, then inspect XML
    local extract_tmp="${RESTORE_TMP}/${vm}_extract"
    rm -rf "${extract_tmp}"
    mkdir -p "${extract_tmp}"

    if [[ "${dry_run}" != "1" ]]; then
      log_message "INFO" "Extracting tarball: ${tarball}"
      if ! tar -xzf "${tarball}" -C "${extract_tmp}"; then
        log_message "ERROR" "Failed to extract tarball: ${tarball}"
        update_status "${vm}" "error" "Tarball extraction failed"
        (( RESTORE_ERRORS++ )) || true
        return 1
      fi
    else
      log_message "DRY-RUN" "Would extract tarball: ${tarball} -> ${extract_tmp}"
    fi

    # Find the XML within the extracted files (strip any timestamp prefix)
    backup_xml=$(find "${extract_tmp}" -name "*.xml" 2>/dev/null | head -1)
  fi

  if [[ -n "${backup_xml}" && -f "${backup_xml}" ]]; then
    # Read disk paths and NVRAM from backup XML
    while IFS= read -r dpath; do
      [[ -n "${dpath}" ]] && disk_paths+=("${dpath}")
    done < <(get_disk_paths_from_xml "${backup_xml}")

    nvram_dest_path=$(get_nvram_path_from_xml "${backup_xml}")
  fi

  log_message "INFO" "Disk destinations from backup XML: ${disk_paths[*]:-none}"
  log_message "INFO" "NVRAM destination from backup XML: ${nvram_dest_path:-none}"

  # ---- Safety backup of current files ----
  log_message "INFO" "Creating pre-restore safety backups..."

  if vm_is_defined "${vm}"; then
    local pre_xml="${RESTORE_TMP}/${vm}.pre_restore.xml"
    if [[ "${dry_run}" != "1" ]]; then
      if virsh dumpxml "${vm}" > "${pre_xml}" 2>/dev/null; then
        log_message "INFO" "Saved current VM XML to: ${pre_xml}"
      else
        log_message "WARN" "Could not dump current XML for VM: ${vm}"
      fi
    else
      log_message "DRY-RUN" "Would save current VM XML to: ${pre_xml}"
    fi
  fi

  # Safety-rename disk image files that exist at destinations
  for dpath in "${disk_paths[@]}"; do
    if [[ -f "${dpath}" ]]; then
      local pre_tmp="${dpath}.pre_restore_tmp"
      if [[ "${dry_run}" != "1" ]]; then
        if mv "${dpath}" "${pre_tmp}"; then
          PRE_RESTORE_TMP_FILES+=("${pre_tmp}")
          log_message "INFO" "Safety renamed: ${dpath} -> ${pre_tmp}"
        else
          log_message "WARN" "Could not safety rename: ${dpath}"
        fi
      else
        log_message "DRY-RUN" "Would safety rename: ${dpath} -> ${pre_tmp}"
      fi
    fi
  done

  # Safety-rename NVRAM if it exists
  if [[ -n "${nvram_dest_path}" && -f "${nvram_dest_path}" ]]; then
    local nvram_pre_tmp="${nvram_dest_path}.pre_restore_tmp"
    if [[ "${dry_run}" != "1" ]]; then
      if mv "${nvram_dest_path}" "${nvram_pre_tmp}"; then
        PRE_RESTORE_TMP_FILES+=("${nvram_pre_tmp}")
        log_message "INFO" "Safety renamed NVRAM: ${nvram_dest_path} -> ${nvram_pre_tmp}"
      else
        log_message "WARN" "Could not safety rename NVRAM: ${nvram_dest_path}"
      fi
    else
      log_message "DRY-RUN" "Would safety rename NVRAM: ${nvram_dest_path} -> ${nvram_pre_tmp}"
    fi
  fi

  # ---- Restore files ----
  local restore_failed=0

  case "${format}" in
    uncompressed)
      restore_uncompressed "${vm}" "${vm_backup_dir}" "${prefix}" "${xml_dest}" "${nvram_dest_path}" disk_paths || restore_failed=1
      ;;
    zstd)
      restore_zstd "${vm}" "${vm_backup_dir}" "${prefix}" "${xml_dest}" "${nvram_dest_path}" disk_paths || restore_failed=1
      ;;
    targz)
      restore_targz "${vm}" "${extract_tmp}" "${xml_dest}" "${nvram_dest_path}" disk_paths || restore_failed=1
      ;;
  esac

  if [[ ${restore_failed} -ne 0 ]]; then
    log_message "ERROR" "File restore failed for VM: ${vm}"
    update_status "${vm}" "error" "File restore failed"
    (( RESTORE_ERRORS++ )) || true
    return 1
  fi

  # ---- Define VM in libvirt ----
  if [[ -f "${xml_dest}" ]]; then
    if [[ "${dry_run}" != "1" ]]; then
      log_message "INFO" "Defining VM in libvirt: virsh define ${xml_dest}"
      if ! virsh define "${xml_dest}"; then
        log_message "ERROR" "virsh define failed for: ${xml_dest}"
        update_status "${vm}" "error" "virsh define failed"
        (( RESTORE_ERRORS++ )) || true
        return 1
      fi
      log_message "INFO" "VM defined successfully: ${vm}"
    else
      log_message "DRY-RUN" "Would run: virsh define ${xml_dest}"
    fi
  else
    log_message "WARN" "XML destination not found after restore; skipping virsh define: ${xml_dest}"
  fi

  # ---- Cleanup safety backups on success ----
  log_message "INFO" "Removing pre-restore safety backups..."
  local remaining_pre_tmp=()
  for pre_tmp in "${PRE_RESTORE_TMP_FILES[@]}"; do
    if [[ -f "${pre_tmp}" ]]; then
      if [[ "${dry_run}" != "1" ]]; then
        if rm -f "${pre_tmp}"; then
          log_message "INFO" "Removed safety backup: ${pre_tmp}"
        else
          log_message "WARN" "Could not remove safety backup: ${pre_tmp}"
          remaining_pre_tmp+=("${pre_tmp}")
        fi
      else
        log_message "DRY-RUN" "Would remove safety backup: ${pre_tmp}"
      fi
    fi
  done
  PRE_RESTORE_TMP_FILES=("${remaining_pre_tmp[@]}")

  log_message "INFO" "Restore complete for VM: ${vm}"
  update_status "${vm}" "complete" "Restore finished successfully"
  return 0
}

# Restore uncompressed backup files
restore_uncompressed() {
  local vm="${1}"
  local src_dir="${2}"
  local prefix="${3}"
  local xml_dest="${4}"
  local nvram_dest="${5}"
  local -n _disk_paths="${6}"   # nameref to disk_paths array

  log_message "INFO" "Restoring uncompressed files from: ${src_dir}"

  local errors=0
  local found_files=()
  while IFS= read -r -d '' f; do
    found_files+=("${f}")
  done < <(find "${src_dir}" -maxdepth 1 -name "${prefix}*" -print0 2>/dev/null | sort -z)

  if [[ ${#found_files[@]} -eq 0 ]]; then
    log_message "ERROR" "No files found matching prefix '${prefix}' in ${src_dir}"
    return 1
  fi

  for backup_file in "${found_files[@]}"; do
    local basename
    basename=$(basename "${backup_file}")
    local stripped="${basename#"${prefix}"}"

    if [[ "${backup_file}" == *.xml ]]; then
      log_message "INFO" "Restoring XML: ${backup_file} -> ${xml_dest}"
      if [[ "${dry_run}" != "1" ]]; then
        mkdir -p "$(dirname "${xml_dest}")"
        cp "${backup_file}" "${xml_dest}" || { log_message "ERROR" "Failed: ${backup_file} -> ${xml_dest}"; (( errors++ )) || true; }
      else
        log_message "DRY-RUN" "Would copy XML: ${backup_file} -> ${xml_dest}"
      fi

    elif [[ "${backup_file}" == *.fd ]]; then
      local nvram_dst
      nvram_dst="${nvram_dest:-/etc/libvirt/qemu/nvram/${stripped}}"
      log_message "INFO" "Restoring NVRAM: ${backup_file} -> ${nvram_dst}"
      if [[ "${dry_run}" != "1" ]]; then
        mkdir -p "$(dirname "${nvram_dst}")"
        cp "${backup_file}" "${nvram_dst}" || { log_message "ERROR" "Failed NVRAM copy: ${backup_file} -> ${nvram_dst}"; (( errors++ )) || true; }
      else
        log_message "DRY-RUN" "Would copy NVRAM: ${backup_file} -> ${nvram_dst}"
      fi

    elif [[ -f "${backup_file}" ]]; then
      # Disk image
      local disk_dst=""
      for dpath in "${_disk_paths[@]}"; do
        if [[ "$(basename "${dpath}")" == "${stripped}" ]]; then
          disk_dst="${dpath}"
          break
        fi
      done

      if [[ -z "${disk_dst}" ]]; then
        log_message "WARN" "No destination mapping for disk file: ${stripped}; skipping"
        continue
      fi

      copy_with_fallback "${backup_file}" "${disk_dst}" || { (( errors++ )) || true; }
    fi
  done

  return ${errors}
}

# Restore zstd-compressed backup files
restore_zstd() {
  local vm="${1}"
  local src_dir="${2}"
  local prefix="${3}"
  local xml_dest="${4}"
  local nvram_dest="${5}"
  local -n _disk_paths_z="${6}"

  log_message "INFO" "Restoring zstd-compressed files from: ${src_dir}"

  local errors=0
  local found_files=()
  while IFS= read -r -d '' f; do
    found_files+=("${f}")
  done < <(find "${src_dir}" -maxdepth 1 -name "${prefix}*" -print0 2>/dev/null | sort -z)

  if [[ ${#found_files[@]} -eq 0 ]]; then
    log_message "ERROR" "No files found matching prefix '${prefix}' in ${src_dir}"
    return 1
  fi

  for backup_file in "${found_files[@]}"; do
    local basename
    basename=$(basename "${backup_file}")
    local stripped="${basename#"${prefix}"}"

    if [[ "${backup_file}" == *.xml ]]; then
      log_message "INFO" "Restoring XML: ${backup_file} -> ${xml_dest}"
      if [[ "${dry_run}" != "1" ]]; then
        mkdir -p "$(dirname "${xml_dest}")"
        cp "${backup_file}" "${xml_dest}" || { log_message "ERROR" "Failed XML copy"; (( errors++ )) || true; }
      else
        log_message "DRY-RUN" "Would copy XML: ${backup_file} -> ${xml_dest}"
      fi

    elif [[ "${backup_file}" == *.fd ]]; then
      local nvram_dst="${nvram_dest:-/etc/libvirt/qemu/nvram/${stripped}}"
      log_message "INFO" "Restoring NVRAM: ${backup_file} -> ${nvram_dst}"
      if [[ "${dry_run}" != "1" ]]; then
        mkdir -p "$(dirname "${nvram_dst}")"
        cp "${backup_file}" "${nvram_dst}" || { log_message "ERROR" "Failed NVRAM copy"; (( errors++ )) || true; }
      else
        log_message "DRY-RUN" "Would copy NVRAM: ${backup_file} -> ${nvram_dst}"
      fi

    elif [[ "${backup_file}" == *.zst && -f "${backup_file}" ]]; then
      # Compressed disk image — strip .zst extension too
      local stripped_nodot="${stripped%.zst}"

      local disk_dst=""
      for dpath in "${_disk_paths_z[@]}"; do
        if [[ "$(basename "${dpath}")" == "${stripped_nodot}" ]]; then
          disk_dst="${dpath}"
          break
        fi
      done

      if [[ -z "${disk_dst}" ]]; then
        log_message "WARN" "No destination mapping for zst file: ${stripped_nodot}; skipping"
        continue
      fi

      log_message "INFO" "Decompressing zstd: ${backup_file} -> ${disk_dst}"
      if [[ "${dry_run}" != "1" ]]; then
        mkdir -p "$(dirname "${disk_dst}")"
        if ! zstd -d "${backup_file}" -o "${disk_dst}" --force; then
          log_message "ERROR" "zstd decompress failed: ${backup_file} -> ${disk_dst}"
          (( errors++ )) || true
        fi
      else
        log_message "DRY-RUN" "Would decompress: ${backup_file} -> ${disk_dst}"
      fi

    elif [[ -f "${backup_file}" ]]; then
      # Uncompressed file in a zstd backup set (shouldn't normally happen but handle gracefully)
      local disk_dst=""
      for dpath in "${_disk_paths_z[@]}"; do
        if [[ "$(basename "${dpath}")" == "${stripped}" ]]; then
          disk_dst="${dpath}"
          break
        fi
      done
      [[ -n "${disk_dst}" ]] && copy_with_fallback "${backup_file}" "${disk_dst}" || true
    fi
  done

  return ${errors}
}

# Restore tar.gz bundle (files have already been extracted to extract_tmp)
restore_targz() {
  local vm="${1}"
  local extract_tmp="${2}"
  local xml_dest="${3}"
  local nvram_dest="${4}"
  local -n _disk_paths_t="${5}"

  log_message "INFO" "Restoring from extracted tarball contents in: ${extract_tmp}"

  if [[ "${dry_run}" == "1" ]]; then
    log_message "DRY-RUN" "Would restore tarball contents (skipping in dry run)"
    return 0
  fi

  local errors=0

  while IFS= read -r -d '' extracted_file; do
    [[ -f "${extracted_file}" ]] || continue

    local basename
    basename=$(basename "${extracted_file}")

    if [[ "${extracted_file}" == *.xml ]]; then
      log_message "INFO" "Restoring XML from tarball: ${extracted_file} -> ${xml_dest}"
      mkdir -p "$(dirname "${xml_dest}")"
      cp "${extracted_file}" "${xml_dest}" || { log_message "ERROR" "Failed XML copy"; (( errors++ )) || true; }

    elif [[ "${extracted_file}" == *.fd ]]; then
      local nvram_dst="${nvram_dest:-/etc/libvirt/qemu/nvram/${basename}}"
      log_message "INFO" "Restoring NVRAM from tarball: ${extracted_file} -> ${nvram_dst}"
      mkdir -p "$(dirname "${nvram_dst}")"
      cp "${extracted_file}" "${nvram_dst}" || { log_message "ERROR" "Failed NVRAM copy"; (( errors++ )) || true; }

    else
      # Disk image
      local disk_dst=""
      for dpath in "${_disk_paths_t[@]}"; do
        if [[ "$(basename "${dpath}")" == "${basename}" ]]; then
          disk_dst="${dpath}"
          break
        fi
      done

      if [[ -z "${disk_dst}" ]]; then
        log_message "WARN" "No destination mapping for extracted file: ${basename}; skipping"
        continue
      fi

      copy_with_fallback "${extracted_file}" "${disk_dst}" || { (( errors++ )) || true; }
    fi

  done < <(find "${extract_tmp}" -type f -print0 2>/dev/null)

  return ${errors}
}

send_notification() {
  local subject="${1}"
  local description="${2}"
  local level="${3:-normal}"   # normal or warning

  local notify_script="/usr/local/emhttp/plugins/dynamix/scripts/notify"
  if [[ -x "${notify_script}" ]]; then
    "${notify_script}" -e "VM Backup" -s "${subject}" -d "${description}" -i "${level}"
  else
    log_message "WARN" "Notification script not found: ${notify_script}"
  fi
}

################################################## functions end ################################################################


################################################## main start ###################################################################

# ---- Initialization ----
mkdir -p "${RESTORE_TMP}"
echo $$ > "${PID_FILE}"

# Set up logging (tee to log file)
exec > >(tee -a "${LOG_FILE}") 2>&1

# Register cleanup trap
trap cleanup EXIT INT TERM

log_message "INFO" "vmbackup restore script starting (PID: $$)"
log_message "INFO" "Log file: ${LOG_FILE}"

# ---- Source restore configuration ----
if [[ ! -f "${RESTORE_CFG}" ]]; then
  log_message "ERROR" "Restore config not found: ${RESTORE_CFG}"
  exit 1
fi

# shellcheck source=/dev/null
source "${RESTORE_CFG}"

log_message "INFO" "Loaded config: ${RESTORE_CFG}"
log_message "INFO" "Backup location: ${backup_location}"
log_message "INFO" "Dry run: ${dry_run:-0}"

# Normalize dry_run
dry_run="${dry_run:-0}"

# ---- Validate backup location ----
if [[ -z "${backup_location}" || ! -d "${backup_location}" ]]; then
  log_message "ERROR" "backup_location is not set or does not exist: ${backup_location}"
  exit 1
fi

# ---- Validate restore_vms ----
if [[ -z "${restore_vms}" ]]; then
  log_message "ERROR" "restore_vms is not set in ${RESTORE_CFG}"
  exit 1
fi

# ---- Parse restore_vms JSON ----
log_message "INFO" "Parsing restore_vms: ${restore_vms}"

declare -a VM_LIST=()
declare -a VERSION_LIST=()

while IFS=$'\t' read -r vm version; do
  [[ -z "${vm}" ]] && continue
  VM_LIST+=("${vm}")
  VERSION_LIST+=("${version}")
  log_message "INFO" "Queued restore: VM='${vm}' version='${version:-<latest>}'"
done < <(parse_restore_vms "${restore_vms}")

if [[ ${#VM_LIST[@]} -eq 0 ]]; then
  log_message "ERROR" "No VMs parsed from restore_vms. Check JSON format."
  exit 1
fi

# ---- Initialize status file ----
echo "timestamp|vm|state|message" > "${STATUS_FILE}"

# ---- Restore each VM ----
log_message "INFO" "Starting restore of ${#VM_LIST[@]} VM(s)"

for (( i=0; i<${#VM_LIST[@]}; i++ )); do
  vm="${VM_LIST[$i]}"
  version="${VERSION_LIST[$i]}"

  # Check stop flag before each VM
  if [[ -f "${STOP_FILE}" ]]; then
    log_message "WARN" "Stop file detected. Halting restore queue."
    break
  fi

  restore_vm "${vm}" "${version}" || true
done

# ---- Final summary ----
log_message "INFO" "=========================================="
if [[ ${RESTORE_ERRORS} -eq 0 ]]; then
  log_message "INFO" "All restores completed successfully."
  send_notification "VM Restore Complete" "All ${#VM_LIST[@]} VM(s) restored successfully." "normal"
else
  log_message "WARN" "Restore completed with ${RESTORE_ERRORS} error(s). Check the log for details."
  send_notification "VM Restore Complete" "${RESTORE_ERRORS} error(s) occurred during restore of ${#VM_LIST[@]} VM(s). Check logs." "warning"
fi

log_message "INFO" "Restore script finished."

################################################## main end #####################################################################
