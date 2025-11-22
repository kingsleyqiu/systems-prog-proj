#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail


# Paths (home folder version)

ROOT_DIR="$HOME/Documents/systems-prog-proj-main"

# Config directory + files
CONF_PATH="$ROOT_DIR/config"
CONF_FILE="${CONF_PATH}/netwatch.conf"
SERVER_LIST="${CONF_PATH}/server.list"
PROC_LIST="${CONF_PATH}/proc.list"
DIR_LIST="${CONF_PATH}/dir.list"

# Cache + timers live completely inside the project folder
CACHE_DIR="$ROOT_DIR/cache"
TIMERS_DIR="$ROOT_DIR/timers"
LOG_DIR="$ROOT_DIR/logs"

mkdir -p "$CACHE_DIR" "$TIMERS_DIR" "$LOG_DIR"

LOG_FILE_DEFAULT="$LOG_DIR/netwatch.log"

# Time labels (seconds)
THIRTY_MIN=$((60 * 30))
ONE_HOUR=$((60 * 60))
SIX_HOURS=$((60 * 60 * 6))
TWELVE_HOURS=$((60 * 60 * 12))
ONE_DAY=$((60 * 60 * 24))
TWO_DAYS=$((ONE_DAY * 2))

SERVICE_COMMAND=""

#  Configuration loading
load_conf() {
echo "Loading configuration..."

  # Defaults (can be overridden by config)
  EMAIL_TO="root"
  CUSTOM_EMAIL_COMMAND=""
  ALLOW_THREADING=1

  CPU_SCAN_INTERVAL=30
  MEM_SCAN_INTERVAL=30
  DISK_SCAN_INTERVAL=$THIRTY_MIN
  PROC_SCAN_INTERVAL=$((60 * 3))
  SERVERS_SCAN_INTERVAL=$((60 * 5))
  DIRECTORIES_SCAN_INTERVAL=$ONE_DAY

  CPU_EMAIL_WARN_INTERVAL=$ONE_DAY
  CPU_EMAIL_CRIT_INTERVAL=$ONE_HOUR
  MEM_EMAIL_WARN_INTERVAL=$ONE_DAY
  MEM_EMAIL_CRIT_INTERVAL=$SIX_HOURS
  DISK_EMAIL_WARN_INTERVAL=$ONE_DAY
  DISK_EMAIL_CRIT_INTERVAL=$SIX_HOURS
  PROC_EMAIL_INTERVAL=$((60 * 5))
  SERVERS_EMAIL_INTERVAL=$SIX_HOURS
  DIRECTORIES_EMAIL_INTERVAL=$SIX_HOURS

  WARNING_CPU=75
  WARNING_MEM=75
  WARNING_SWAP=65
  WARNING_DISK=75
  CRITICAL_CPU=95
  CRITICAL_MEM=90
  CRITICAL_SWAP=80
  CRITICAL_DISK=90

  # Load config file if it exists
  if [[ -f "$CONF_FILE" ]]; then
    # shellcheck source=/dev/null
    . "$CONF_FILE"
  fi

  # If new-style ALERT_EMAIL is set, map it to EMAIL_TO
  if [[ "${ALERT_EMAIL:-}" != "" ]]; then
    EMAIL_TO="$ALERT_EMAIL"
  fi

  # If LOG_FILE is not set in config, fall back to default
  LOG_FILE="${LOG_FILE:-$LOG_FILE_DEFAULT}"

  detect_service_command
}

#  Logging
log_msg() {
  mkdir -p "$(dirname "$LOG_FILE")"

  if [[ ! -e "$LOG_FILE" ]]; then
    touch "$LOG_FILE"
    chmod 0640 "$LOG_FILE"
  fi

  echo "$(date +'[%Y-%m-%d %T]') $1" >> "$LOG_FILE"
}

# elapsed_time <key> <interval_seconds>
# Returns:
#   1 if enough time has passed (caller should proceed)
#   0 if not enough time has passed (caller should skip)
elapsed_time() {
  local key="$1"
  local interval="$2"
  local time_file="$TIMERS_DIR/${key}.time"

  if [[ ! -e "$time_file" ]]; then
    date +"%s" > "$time_file"
    return 1
  else
    local previous_time current_time elapsed
    previous_time="$(cat "$time_file" 2>/dev/null || echo 0)"
    current_time="$(date +"%s")"
    elapsed=$(( current_time - previous_time ))

    if (( elapsed >= interval )); then
      date +"%s" > "$time_file"
      return 1
    fi
  fi

  return 0
}

#  Service command detection
detect_service_command() {
  SERVICE_COMMAND=""

  if [[ -d /etc/init.d ]]; then
    # Check if service is installed
    local SERVICE_PATH
    SERVICE_PATH="$(whereis service)"
    if [[ "$SERVICE_PATH" != "service:" ]]; then
      SERVICE_COMMAND="service"
    else
      SERVICE_COMMAND="initd"
    fi
  elif [[ -d /usr/lib/systemd/system ]]; then
    # Check if systemctl is installed
    local SYSTEMCTL_PATH
    SYSTEMCTL_PATH="$(whereis systemctl)"
    if [[ "$SYSTEMCTL_PATH" != "systemctl:" ]]; then
      SERVICE_COMMAND="systemctl"
    fi
  fi

  if [[ "$SERVICE_COMMAND" = "" ]]; then
    log_msg "error: command to start services not detected"
    echo "error: command to start services not detected" 1>&2
    exit 1
  fi
}

# Start a service using appropriate command
start_service() {
  local svc="$1"

  if [[ "$SERVICE_COMMAND" = "systemctl" ]]; then
    systemctl start "$svc"
  elif [[ "$SERVICE_COMMAND" = "service" ]]; then
    service "$svc" start
  elif [[ "$SERVICE_COMMAND" = "initd" ]]; then
    "/etc/init.d/$svc" start
  else
    log_msg "error: command to start services not detected"
    exit 1
  fi
}

#  Email sending
# send_email <subject> <body_file>
send_email() {
  local subject="$1"
  local body_file="$2"

  if [[ "${CUSTOM_EMAIL_COMMAND:-}" != "" ]]; then
    # Custom mail command handles params itself
    $CUSTOM_EMAIL_COMMAND "$EMAIL_TO" "$subject" "$body_file" &
    return
  fi

  local message
  message="$(mail -s "$subject" "$EMAIL_TO" < "$body_file" 2>&1 || true)"

  if echo "$message" | grep -qi "not sent"; then
    log_msg "error: could not send alert e-mail"
  fi
}

#  Monitoring: Memory / Swap
monitor_memory_usage() {
  elapsed_time "mem_usage" "$MEM_SCAN_INTERVAL"
  if [[ "$?" -eq 0 ]]; then
    return
  fi

  local MEM_USAGE_FILE="$CACHE_DIR/mem_usage.txt"

  local TOTAL_MEM TOTAL_SWP TOTAL_MEM_INT TOTAL_SWP_INT

  TOTAL_MEM=$(free -mt | \
    grep "Mem:" | \
    awk '{print $2 " " $3}' | \
    awk '{ if($2 > 0) print $2 / $1 * 100; else print 0 }'
  )

  TOTAL_SWP=$(free -mt | \
    grep "Swap:" | \
    awk '{print $2 " " $3}' | \
    awk '{ if($2 > 0) print $2 / $1 * 100; else print 0 }'
  )

  {
    echo "Output of free -mt"
    echo
    free -m -t
    echo
    echo "Output of top -b -n 2"
    echo
    top -b -n 2
  } > "$MEM_USAGE_FILE"

  TOTAL_MEM_INT="$(echo "$TOTAL_MEM" | cut -d"." -f1)"
  TOTAL_SWP_INT="$(echo "$TOTAL_SWP" | cut -d"." -f1)"

  # Critical memory
  if [[ "$TOTAL_MEM_INT" -ge "$CRITICAL_MEM" ]]; then
    log_msg "critical: memory usage reached ${TOTAL_MEM}%"

    elapsed_time "mem_email_critical" "$MEM_EMAIL_CRIT_INTERVAL"
    if [[ "$?" -ge 1 ]]; then
      send_email "Critical: Memory Usage ${TOTAL_MEM}%" "$MEM_USAGE_FILE"
    fi

  # Warning memory
  elif [[ "$TOTAL_MEM_INT" -ge "$WARNING_MEM" ]]; then
    log_msg "warning: memory usage reached ${TOTAL_MEM}%"

    elapsed_time "mem_email_warning" "$MEM_EMAIL_WARN_INTERVAL"
    if [[ "$?" -ge 1 ]]; then
      send_email "Warning: Memory Usage ${TOTAL_MEM}%" "$MEM_USAGE_FILE"
    fi
  fi

  # Critical swap
  if [[ "$TOTAL_SWP_INT" -ge "$CRITICAL_SWAP" ]]; then
    log_msg "critical: swap usage reached ${TOTAL_SWP}%"

    elapsed_time "swap_email_critical" "$MEM_EMAIL_CRIT_INTERVAL"
    if [[ "$?" -ge 1 ]]; then
      send_email "Critical: Swap Usage ${TOTAL_SWP}%" "$MEM_USAGE_FILE"
    fi

  # Warning swap
  elif [[ "$TOTAL_SWP_INT" -ge "$WARNING_SWAP" ]]; then
    log_msg "warning: swap usage reached ${TOTAL_SWP}%"

    elapsed_time "swap_email_warning" "$MEM_EMAIL_WARN_INTERVAL"
    if [[ "$?" -ge 1 ]]; then
      send_email "Warning: Swap Usage ${TOTAL_SWP}%" "$MEM_USAGE_FILE"
    fi
  fi
}

#  Monitoring: CPU
monitor_cpu_usage() {
  echo "Function monitor_cpu_usage started."  # This confirms the function is called.

  # Check if enough time has passed since the last CPU check
#  elapsed_time "cpu_usage" "$CPU_SCAN_INTERVAL"
 # if [[ "$?" -eq 0 ]]; then
  #  return
 # fi
  echo "Inside monitor_cpu_usage function..."

  # Set the file to store CPU usage output
  local CPU_USAGE_FILE="$CACHE_DIR/cpu_usage.txt"

  # Get the number of CPU cores (or threads)
  local CPU_COUNT
  CPU_COUNT="$(top -bn1 | grep -c 'Cpu')"

  # Collect top command output and save it to the file
  {
    echo "Output of top -b -n 2"
    echo
    top -b -n 2
  } > "$CPU_USAGE_FILE"

  # Extract the CPU usage percentage
  local USAGE_TOTAL TOTAL TOTAL_INT
  USAGE_TOTAL=$(grep Cpu "$CPU_USAGE_FILE" | \
    grep -o -e "[0-9]\+\.[0-9]\+ us" | \
    grep -o -e "[0-9]\+\.[0-9]\+" | \
    tail -n +"$((CPU_COUNT + 1))" | \
    awk '{sum += $1}; END {print sum}'
  )

  # Calculate total CPU usage (percentage)
  TOTAL=$(echo "$USAGE_TOTAL $CPU_COUNT" | \
    awk '{ if($2 > 0) print $1 / $2; else print 0 }'
  )

  # Convert total usage to an integer
  TOTAL_INT="$(echo "$TOTAL" | cut -d"." -f1)"

  # Check if the CPU usage exceeds the critical threshold
  if [[ "$TOTAL_INT" -ge "$CRITICAL_CPU" ]]; then
    log_msg "critical: cpu usage reached ${TOTAL}%"

    # Send a critical CPU usage alert if the time interval has passed
    elapsed_time "cpu_email_critical" "$CPU_EMAIL_CRIT_INTERVAL"
    if [[ "$?" -eq 1 ]]; then
      send_email "Critical: CPU Usage ${TOTAL}%" "$CPU_USAGE_FILE"
    fi

  # Check if the CPU usage exceeds the warning threshold
  elif [[ "$TOTAL_INT" -ge "$WARNING_CPU" ]]; then
    log_msg "warning: cpu usage reached ${TOTAL}%"

    # Send a warning CPU usage alert if the time interval has passed
    elapsed_time "cpu_email_warning" "$CPU_EMAIL_WARN_INTERVAL"
    if [[ "$?" -eq 1 ]]; then
      send_email "Warning: CPU Usage ${TOTAL}%" "$CPU_USAGE_FILE"
    fi
  fi
  echo "Exiting monitor_cpu_usage function."
}


#  Monitoring: Disk
monitor_disk_usage() {
  elapsed_time "disk_usage" "$DISK_SCAN_INTERVAL"
  if [[ "$?" -eq 0 ]]; then
    return
  fi

  local DISK_USAGE_FILE="$CACHE_DIR/disk_usage.txt"
  local CRITICAL_USAGE=0
  local WARNING_USAGE=0

  {
    echo "Output of df -h"
    echo
    df -h
  } > "$DISK_USAGE_FILE"

  while read -r line; do
    local DEVICE USAGE
    DEVICE="$(echo "$line" | awk '{print $1}')"
    USAGE="$(echo "$line" | awk '{print $5}' | sed 's/%//')"

    if [[ -z "$DEVICE" || -z "$USAGE" ]]; then
      continue
    fi

    if [[ "$USAGE" -ge "$CRITICAL_DISK" ]]; then
      log_msg "critical: disk usage reached ${USAGE}% on $DEVICE"
      CRITICAL_USAGE=1
    elif [[ "$USAGE" -ge "$WARNING_DISK" ]]; then
      log_msg "warning: disk usage reached ${USAGE}% on $DEVICE"
      WARNING_USAGE=1
    fi
  done < <(grep -v "tmp" "$DISK_USAGE_FILE" | grep "/dev/")

  if [[ "$CRITICAL_USAGE" -eq 1 ]]; then
    elapsed_time "disk_email_critical" "$DISK_EMAIL_CRIT_INTERVAL"
    if [[ "$?" -eq 1 ]]; then
      send_email "Critical: Disk Usage" "$DISK_USAGE_FILE"
    fi
  elif [[ "$WARNING_USAGE" -eq 1 ]]; then
    elapsed_time "disk_email_warning" "$DISK_EMAIL_WARN_INTERVAL"
    if [[ "$?" -eq 1 ]]; then
      send_email "Warning: Disk Usage" "$DISK_USAGE_FILE"
    fi
  fi
}

#  Monitoring: Directories (integrity)
monitor_directories() {
  elapsed_time "directories_status" "$DIRECTORIES_SCAN_INTERVAL"
  if [[ "$?" -eq 0 ]]; then
    return
  fi

  local STATUS_FILE="$CACHE_DIR/directories_status.txt"
  local STATUS_FILE_NEW="$CACHE_DIR/directories_status_new.txt"
  local EMAIL_FILE="$CACHE_DIR/directories_email.txt"
  local DIFF_FILE="$CACHE_DIR/directories_diff.txt"

  local FIRST_TIME=0
  local FILES_CHANGED=0

  if [[ ! -e "$STATUS_FILE" ]]; then
    FIRST_TIME=1
  fi

  : > "$STATUS_FILE_NEW"

  while read -r line; do
    line="$(echo "$line" | sed 's/ //g')"
    [[ -z "$line" || "$line" =~ ^# ]] && continue

    while read -r file; do
      if [[ -f "$file" ]]; then
        md5sum "$file" >> "$STATUS_FILE_NEW"
      fi
    done < <(find "$line" -type f 2>/dev/null)
  done < "$DIR_LIST"

  if [[ "$FIRST_TIME" -eq 1 ]]; then
    cp "$STATUS_FILE_NEW" "$STATUS_FILE"
  else
    diff -u "$STATUS_FILE" "$STATUS_FILE_NEW" > "$DIFF_FILE" || true
    local CHANGES_SIZE
    CHANGES_SIZE="$(stat -c%s "$DIFF_FILE" 2>/dev/null || echo 0)"

    if [[ "$CHANGES_SIZE" -ne 0 ]]; then
      FILES_CHANGED=1
    fi
  fi

  if [[ "$FILES_CHANGED" -eq 1 ]]; then
    elapsed_time "directories_email_status" "$DIRECTORIES_EMAIL_INTERVAL"
    if [[ "$?" -eq 0 ]]; then
      return
    fi

    {
      echo "Below is a partial diff showing the file changes"
      echo "================================================="
      grep "^[-+]" "$DIFF_FILE"
    } > "$EMAIL_FILE"

    send_email "Warning: files have changed" "$EMAIL_FILE"
    cp "$STATUS_FILE_NEW" "$STATUS_FILE"
  fi

  rm -f "$DIFF_FILE" "$EMAIL_FILE" "$STATUS_FILE_NEW"
}

#  Monitoring: Servers (ping/port)
monitor_servers() {
  elapsed_time "servers_status" "$SERVERS_SCAN_INTERVAL"
  if [[ "$?" -eq 0 ]]; then
    return
  fi

  local STATUS_FILE="$CACHE_DIR/servers_status.txt"
  local SERVER_OFFLINE=0

  {
    echo "Offline servers:"
    echo
  } > "$STATUS_FILE"

  [[ -f "$SERVER_LIST" ]] || return

  while read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue

    local ip port
    ip="$(echo "$line" | cut -d":" -f1 | xargs)"
    port="$(echo "$line" | cut -d":" -f2 | xargs)"

    if [[ -n "$port" && "$port" != "none" && "$port" != "NONE" ]]; then
      echo "QUIT" | nc -w 5 -z "$ip" "$port" > /dev/null 2>&1 || {
        log_msg "warning: server $ip:$port seems offline"
        echo "$ip:$port" >> "$STATUS_FILE"
        SERVER_OFFLINE=1
      }
    else
      ping -c 1 "$ip" > /dev/null 2>&1 || {
        log_msg "warning: server $ip seems offline"
        echo "$ip" >> "$STATUS_FILE"
        SERVER_OFFLINE=1
      }
    fi
  done < "$SERVER_LIST"

  if [[ "$SERVER_OFFLINE" -eq 1 ]]; then
    elapsed_time "servers_email_status" "$SERVERS_EMAIL_INTERVAL"
    if [[ "$?" -eq 0 ]]; then
      return
    fi
    send_email "Warning: Servers seem offline" "$STATUS_FILE"
  fi
}

#  Monitoring: Services / Processes
monitor_services() {
  elapsed_time "services_status" "$PROC_SCAN_INTERVAL"
  if [[ "$?" -eq 0 ]]; then
    return
  fi

  local STATUS_FILE="$CACHE_DIR/services_status.txt"
  local SERVICES_DOWN=0

  {
    echo "Services status:"
    echo
  } > "$STATUS_FILE"

  [[ -f "$PROC_LIST" ]] || return

  while read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue

    local process service command
    process="$(echo "$line" | cut -d":" -f1 | xargs)"
    service="$(echo "$line" | cut -d":" -f2 | xargs)"
    command="$(echo "$line" | cut -d":" -f3 | xargs)"

    if ps -A | grep -q "$process"; then
      continue
    fi

    SERVICES_DOWN=1

    log_msg "warning: service $service not running"
    echo "service $service not running" >> "$STATUS_FILE"

    if echo "$command" | grep -qi "default"; then
      start_service "$service"
    elif [[ -n "$command" ]]; then
      $command &
    fi
  done < "$PROC_LIST"

  if [[ "$SERVICES_DOWN" -eq 1 ]]; then
    elapsed_time "services_email_status" "$PROC_EMAIL_INTERVAL"
    if [[ "$?" -eq 0 ]]; then
      return
    fi

    send_email "Warning: Services may have crashed" "$STATUS_FILE"
  fi
}

#  Main entry
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

Exit codes:
  0  Success
  1  Configuration / environment error
  2  Invalid arguments
EOF
}

main() {
  load_conf

  local cmd="${1:-all}"

  case "$cmd" in
    all)
      run_all_checks
      ;;
    mem)
      monitor_memory_usage
      ;;
    cpu)
      monitor_cpu_usage
      ;;
    disk)
      monitor_disk_usage
      ;;
    dirs|directories)
      monitor_directories
      ;;
    servers)
      monitor_servers
      ;;
    services)
      monitor_services
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      echo "Invalid command: $cmd" >&2
      usage
      exit 2
      ;;
  esac
}

main "$@"

