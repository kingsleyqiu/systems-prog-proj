#!/usr/bin/env bash
# netwatch.sh - main library + entrypoint for NetWatch monitoring
# Designed so it can be sourced by small wrappers (cpu.sh, mem.sh, disk.sh) or executed directly.

set -o errexit
set -o nounset
set -o pipefail

# Paths & defaults

ROOT_DIR="${HOME}/netwatch"
CONF_PATH="${ROOT_DIR}/config"
CONF_FILE="${CONF_PATH}/netwatch.conf"
SERVER_LIST="${CONF_PATH}/server.list"
PROC_LIST="${CONF_PATH}/proc.list"
DIR_LIST="${CONF_PATH}/dir.list"

CACHE_DIR="${ROOT_DIR}/cache"
TIMERS_DIR="${ROOT_DIR}/timers"
LOG_DIR="${ROOT_DIR}/logs"

mkdir -p "$CACHE_DIR" "$TIMERS_DIR" "$LOG_DIR"

LOG_FILE_DEFAULT="${LOG_DIR}/netwatch.log"
LOG_FILE="$LOG_FILE_DEFAULT"


SERVICE_COMMAND=""


# Utilities

log_msg() {
  local msg="$1"
  mkdir -p "$(dirname "$LOG_FILE")"
  if [[ ! -e "$LOG_FILE" ]]; then
    : > "$LOG_FILE"
    chmod 0640 "$LOG_FILE" || true
  fi
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %T')" "$msg" >> "$LOG_FILE"
}

# should_run <key> <interval_seconds>
# returns 0 if enough time passed (caller should run), 1 otherwise
should_run() {
  local key="$1"; shift
  local interval="$1"; shift
  local time_file="${TIMERS_DIR}/${key}.time"

  if [[ ! -e "$time_file" ]]; then
    date +"%s" > "$time_file"
    return 0
  fi

  local prev now elapsed
  prev="$(cat "$time_file" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  elapsed=$((now - prev))

  if (( elapsed >= interval )); then
    date +"%s" > "$time_file"
    return 0
  fi

  return 1
}

# command exists helper
cmd_exists() { command -v "$1" >/dev/null 2>&1; }


# Config loading

load_conf() {
  # defaults (these can be overridden in $CONF_FILE)
  EMAIL_TO="root"
  CUSTOM_EMAIL_COMMAND=""
  ALLOW_THREADING=1

  # intervals (seconds)
  CPU_SCAN_INTERVAL=30
  MEM_SCAN_INTERVAL=30
  DISK_SCAN_INTERVAL=$((60 * 30))
  PROC_SCAN_INTERVAL=$((60 * 3))
  SERVERS_SCAN_INTERVAL=$((60 * 5))
  DIRECTORIES_SCAN_INTERVAL=$((60 * 60 * 24))

  # email throttle intervals
  CPU_EMAIL_WARN_INTERVAL=$((60 * 60))
  CPU_EMAIL_CRIT_INTERVAL=$((60 * 60))
  MEM_EMAIL_WARN_INTERVAL=$((60 * 60))
  MEM_EMAIL_CRIT_INTERVAL=$((60 * 60 * 6))
  DISK_EMAIL_WARN_INTERVAL=$((60 * 60 * 24))
  DISK_EMAIL_CRIT_INTERVAL=$((60 * 60 * 6))
  PROC_EMAIL_INTERVAL=$((60 * 5))
  SERVERS_EMAIL_INTERVAL=$((60 * 60 * 6))
  DIRECTORIES_EMAIL_INTERVAL=$((60 * 60 * 6))

  # thresholds
  WARNING_CPU=75
  WARNING_MEM=75
  WARNING_SWAP=65
  WARNING_DISK=75
  CRITICAL_CPU=95
  CRITICAL_MEM=90
  CRITICAL_SWAP=80
  CRITICAL_DISK=90

  # override defaults from config file if it exists
  if [[ -f "$CONF_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$CONF_FILE"
  fi

  # support alternate variable names (map older config names to current ones)
  : "${ALERT_EMAIL:=${EMAIL_TO:-}}"
  if [[ -n "${ALERT_EMAIL:-}" ]]; then EMAIL_TO="$ALERT_EMAIL"; fi

  # map old names if present (non-exhaustive)
  WARNING_CPU="${WARNING_CPU:-${CPU_WARN:-${CPU_WARN:-$WARNING_CPU}}}"
  CRITICAL_CPU="${CRITICAL_CPU:-${CPU_CRIT:-$CRITICAL_CPU}}"
  WARNING_MEM="${WARNING_MEM:-${MEM_WARN:-$WARNING_MEM}}"
  CRITICAL_MEM="${CRITICAL_MEM:-${MEM_CRIT:-$CRITICAL_MEM}}"
  WARNING_DISK="${WARNING_DISK:-${DISK_WARN:-$WARNING_DISK}}"
  CRITICAL_DISK="${CRITICAL_DISK:-${DISK_CRIT:-$CRITICAL_DISK}}"

  LOG_FILE="${LOG_FILE:-$LOG_FILE_DEFAULT}"

  detect_service_command
}


# Service detection + start

detect_service_command() {
  SERVICE_COMMAND=""
  if cmd_exists systemctl; then
    SERVICE_COMMAND="systemctl"
  elif cmd_exists service; then
    SERVICE_COMMAND="service"
  elif [[ -d /etc/init.d ]]; then
    SERVICE_COMMAND="initd"
  else
    log_msg "error: no service control command found (systemctl/service/init.d)"
    SERVICE_COMMAND=""
  fi
}

start_service() {
  local svc="$1"
  if [[ "$SERVICE_COMMAND" == "systemctl" ]]; then
    systemctl start "$svc"
  elif [[ "$SERVICE_COMMAND" == "service" ]]; then
    service "$svc" start
  elif [[ "$SERVICE_COMMAND" == "initd" ]]; then
    /etc/init.d/"$svc" start || true
  else
    log_msg "error: cannot start service $svc (no service manager detected)"
  fi
}


# Email helper
# send_email <subject> <body_file>

send_email() {
  local subject="$1"
  local bodyfile="$2"

  if [[ -n "${CUSTOM_EMAIL_COMMAND:-}" ]]; then
    # custom command is expected to handle arguments
    $CUSTOM_EMAIL_COMMAND "$EMAIL_TO" "$subject" "$bodyfile" &>/dev/null || log_msg "error: custom email command failed"
    return
  fi

  if cmd_exists mail; then
    mail -s "$subject" "$EMAIL_TO" < "$bodyfile" 2>/dev/null || log_msg "error: mail command failed to send"
  else
    log_msg "warning: no 'mail' command available to deliver alerts (subject: $subject)"
  fi
}


# Monitoring: Memory

monitor_memory_usage() {
  if ! should_run mem_usage "$MEM_SCAN_INTERVAL"; then
    return
  fi

  local MEM_USAGE_FILE="${CACHE_DIR}/mem_usage.txt"
  {
    echo "Output of free -m -t"
    free -m -t || true
    echo
    echo "Top output (non-interactive sample):"
    top -b -n 1 | head -n 40 || true
  } > "$MEM_USAGE_FILE"

  # get percent used memory and swap (integers)
  local mem_perc swap_perc
  mem_perc="$(awk '/Mem:/ { if ($2>0) printf("%d", $3/$2*100); else print 0 }' <(free -m))"
  swap_perc="$(awk '/Swap:/ { if ($2>0) printf("%d", $3/$2*100); else print 0 }' <(free -m))"

  if (( mem_perc >= CRITICAL_MEM )); then
    log_msg "critical: memory usage reached ${mem_perc}%"
    if should_run mem_email_critical "$MEM_EMAIL_CRIT_INTERVAL"; then
      send_email "Critical: Memory Usage ${mem_perc}%" "$MEM_USAGE_FILE"
    fi
  elif (( mem_perc >= WARNING_MEM )); then
    log_msg "warning: memory usage reached ${mem_perc}%"
    if should_run mem_email_warning "$MEM_EMAIL_WARN_INTERVAL"; then
      send_email "Warning: Memory Usage ${mem_perc}%" "$MEM_USAGE_FILE"
    fi
  fi

  if (( swap_perc >= CRITICAL_SWAP )); then
    log_msg "critical: swap usage reached ${swap_perc}%"
    if should_run swap_email_critical "$MEM_EMAIL_CRIT_INTERVAL"; then
      send_email "Critical: Swap Usage ${swap_perc}%" "$MEM_USAGE_FILE"
    fi
  elif (( swap_perc >= WARNING_SWAP )); then
    log_msg "warning: swap usage reached ${swap_perc}%"
    if should_run swap_email_warning "$MEM_EMAIL_WARN_INTERVAL"; then
      send_email "Warning: Swap Usage ${swap_perc}%" "$MEM_USAGE_FILE"
    fi
  fi
}


# Monitoring: CPU (uses /proc/stat snapshot)

# based on two reads of /proc/stat to compute total busy/time delta
monitor_cpu_usage() {
  if ! should_run cpu_usage "$CPU_SCAN_INTERVAL"; then
    return
  fi

  local CPU_USAGE_FILE="${CACHE_DIR}/cpu_usage.txt"
  local stat1 stat2 idle1 idle2 total1 total2 diff_idle diff_total usage
  # read first snapshot
  read -r cpu user nice system idle iowait irq softirq steal guest < /proc/stat
  # sum total1 = user+nice+system+idle+iowait+irq+softirq+steal
  total1=$((user + nice + system + idle + iowait + irq + softirq + steal))
  idle1=$((idle + iowait))
  sleep 1
  read -r cpu user nice system idle iowait irq softirq steal guest < /proc/stat
  total2=$((user + nice + system + idle + iowait + irq + softirq + steal))
  idle2=$((idle + iowait))

  diff_idle=$((idle2 - idle1))
  diff_total=$((total2 - total1))

  if (( diff_total == 0 )); then
    usage=0
  else
    usage=$(( (1000 * (diff_total - diff_idle) / diff_total + 5) / 10 ))  # rounded percent
  fi

  {
    echo "CPU usage sample (calculated): ${usage}%"
    echo
    top -b -n 1 | head -n 20
  } > "$CPU_USAGE_FILE"

  if (( usage >= CRITICAL_CPU )); then
    log_msg "critical: cpu usage reached ${usage}%"
    if should_run cpu_email_critical "$CPU_EMAIL_CRIT_INTERVAL"; then
      send_email "Critical: CPU Usage ${usage}%" "$CPU_USAGE_FILE"
    fi
  elif (( usage >= WARNING_CPU )); then
    log_msg "warning: cpu usage reached ${usage}%"
    if should_run cpu_email_warning "$CPU_EMAIL_WARN_INTERVAL"; then
      send_email "Warning: CPU Usage ${usage}%" "$CPU_USAGE_FILE"
    fi
  fi
}


# Monitoring: Disk

monitor_disk_usage() {
  if ! should_run disk_usage "$DISK_SCAN_INTERVAL"; then
    return
  fi

  local DISK_USAGE_FILE="${CACHE_DIR}/disk_usage.txt"
  {
    echo "Output of df -h"
    df -h || true
  } > "$DISK_USAGE_FILE"

  local critical=0 warn=0
  # parse df and check mounted devices
  while read -r fs size used avail perc mount; do
    # skip lines without percent
    perc="${perc%\%}"
    if [[ -z "$perc" || "$perc" == "Use" ]]; then
      continue
    fi
    if (( perc >= CRITICAL_DISK )); then
      log_msg "critical: disk usage ${perc}% on ${fs} (${mount})"
      critical=1
    elif (( perc >= WARNING_DISK )); then
      log_msg "warning: disk usage ${perc}% on ${fs} (${mount})"
      warn=1
    fi
  done < <(df -P | tail -n +2)

  if (( critical )); then
    if should_run disk_email_critical "$DISK_EMAIL_CRIT_INTERVAL"; then
      send_email "Critical: Disk Usage" "$DISK_USAGE_FILE"
    fi
  elif (( warn )); then
    if should_run disk_email_warning "$DISK_EMAIL_WARN_INTERVAL"; then
      send_email "Warning: Disk Usage" "$DISK_USAGE_FILE"
    fi
  fi
}


# Monitoring: Directories (integrity)

monitor_directories() {
  if ! should_run directories_status "$DIRECTORIES_SCAN_INTERVAL"; then
    return
  fi

  local STATUS_FILE="${CACHE_DIR}/directories_status.txt"
  local NEW_FILE="${CACHE_DIR}/directories_status_new.txt"
  local DIFF_FILE="${CACHE_DIR}/directories_diff.txt"
  local EMAIL_FILE="${CACHE_DIR}/directories_email.txt"

  : > "$NEW_FILE"

  [[ -f "$DIR_LIST" ]] || return

  while IFS= read -r line || [[ -n "$line" ]]; do
    # trim leading/trailing whitespace
    line="${line##*( )}"
    line="${line%%*( )}"
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue

    # find files, md5sum them and sort for deterministic output
    if [[ -d "$line" ]]; then
      find "$line" -type f -print0 2>/dev/null | xargs -0 md5sum 2>/dev/null || true
    fi
  done < "$DIR_LIST" | sort -k2 > "$NEW_FILE"  # sort by filename

  if [[ ! -f "$STATUS_FILE" ]]; then
    cp "$NEW_FILE" "$STATUS_FILE"
    return
  fi

  diff -u "$STATUS_FILE" "$NEW_FILE" > "$DIFF_FILE" || true
  if [[ -s "$DIFF_FILE" ]]; then
    if should_run directories_email_status "$DIRECTORIES_EMAIL_INTERVAL"; then
      {
        echo "Below is a partial diff showing the file changes"
        echo "================================================="
        grep '^[-+]' "$DIFF_FILE" || true
      } > "$EMAIL_FILE"
      send_email "Warning: files have changed" "$EMAIL_FILE"
    fi
    cp "$NEW_FILE" "$STATUS_FILE"
  fi

  rm -f "$NEW_FILE" "$DIFF_FILE" "$EMAIL_FILE" || true
}


# Monitoring: Servers (ping / port)

monitor_servers() {
  if ! should_run servers_status "$SERVERS_SCAN_INTERVAL"; then
    return
  fi

  local STATUS_FILE="${CACHE_DIR}/servers_status.txt"
  : > "$STATUS_FILE"
  local offline=0

  [[ -f "$SERVER_LIST" ]] || return

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line##*( )}"; line="${line%%*( )}"
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue

    ip="${line%%:*}"
    port="${line#*:}"
    # if no colon, port will equal the entire string - handle that
    if [[ "$ip" == "$port" ]]; then
      port="none"
    fi

    if [[ -n "$port" && "$port" != "none" && "$port" != "NONE" ]]; then
      if cmd_exists nc; then
        if ! nc -z -w 5 "$ip" "$port" >/dev/null 2>&1; then
          log_msg "warning: server $ip:$port seems offline"
          echo "$ip:$port" >> "$STATUS_FILE"
          offline=1
        fi
      else
        # fallback: try /dev/tcp (bash) with timeout
        if ! timeout 5 bash -c ">/dev/tcp/${ip}/${port}" >/dev/null 2>&1; then
          log_msg "warning: server $ip:$port seems offline (fallback)"
          echo "$ip:$port" >> "$STATUS_FILE"
          offline=1
        fi
      fi
    else
      if ! ping -c 1 -W 2 "$ip" >/dev/null 2>&1; then
        log_msg "warning: server $ip seems offline (ping failed)"
        echo "$ip" >> "$STATUS_FILE"
        offline=1
      fi
    fi
  done < "$SERVER_LIST"

  if (( offline )); then
    if should_run servers_email_status "$SERVERS_EMAIL_INTERVAL"; then
      send_email "Warning: Servers seem offline" "$STATUS_FILE"
    fi
  fi
}


# Monitoring: Services / Processes

monitor_services() {
  if ! should_run services_status "$PROC_SCAN_INTERVAL"; then
    return
  fi

  local STATUS_FILE="${CACHE_DIR}/services_status.txt"
  : > "$STATUS_FILE"
  local services_down=0

  [[ -f "$PROC_LIST" ]] || return

  while IFS= read -r line || [[ -n "$line" ]]; do
    # trim and skip comment
    line="${line##*( )}"; line="${line%%*( )}"
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue

    # expected format: process:service:command
    IFS=':' read -r process service command <<< "$line"

    # prefer pgrep to avoid substring false-positives
    if pgrep -f -x "$process" >/dev/null 2>&1 || pgrep -f "$process" >/dev/null 2>&1; then
      continue
    fi

    services_down=1
    log_msg "warning: service ${service:-$process} not running"
    echo "service ${service:-$process} not running" >> "$STATUS_FILE"

    # try to restart
    if [[ "${command,,}" == *"default"* ]]; then
      [[ -n "$service" ]] && start_service "$service"
    elif [[ -n "$command" ]]; then
      # run in background
      bash -c "$command" &>/dev/null &
    fi
  done < "$PROC_LIST"

  if (( services_down )); then
    if should_run services_email_status "$PROC_EMAIL_INTERVAL"; then
      send_email "Warning: Services may have crashed" "$STATUS_FILE"
    fi
  fi
}


# Main

run_all_checks() {
  monitor_memory_usage
  monitor_cpu_usage
  monitor_disk_usage
  monitor_directories
  monitor_servers
  monitor_services
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [all|mem|cpu|disk|dirs|servers|services]

  all       Run all checks (default)
  mem       Check memory and swap usage
  cpu       Check CPU usage
  disk      Check disk usage
  dirs      Check directory integrity
  servers   Check remote servers (ping/port)
  services  Check local services/processes
EOF
}

main() {
  load_conf
  local cmd="${1:-all}"
  case "$cmd" in
    all)
  run_all_checks

  echo "========== NETWATCH SUMMARY =========="
  echo "CPU:"
  sed -n '1,3p' "$CACHE_DIR/cpu_usage.txt"
  echo

  echo "MEMORY:"
  sed -n '1,3p' "$CACHE_DIR/mem_usage.txt"
  echo

  echo "DISK:"
  sed -n '1,10p' "$CACHE_DIR/disk_usage.txt"
  echo

  if [[ -f "$CACHE_DIR/servers_status.txt" ]]; then
    echo "SERVERS:"
    cat "$CACHE_DIR/servers_status.txt"
    echo
  fi

  if [[ -f "$CACHE_DIR/services_status.txt" ]]; then
    echo "SERVICES:"
    cat "$CACHE_DIR/services_status.txt"
    echo
  fi

  echo "Logs: $LOG_FILE"
  echo "======================================"
  ;;

    mem) monitor_memory_usage ;;
    cpu) monitor_cpu_usage ;;
    disk) monitor_disk_usage ;;
    dirs|directories) monitor_directories ;;
    servers) monitor_servers ;;
    services) monitor_services ;;
    -h|--help|help) usage ;;
    *) echo "Invalid command: $cmd" >&2; usage; return 2 ;;
  esac
}

# Only run main when executed (not when sourced)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
