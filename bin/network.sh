#!/usr/bin/env bash
# network.sh - monitor network interfaces (bandwidth & errors)
# Requirements: bash, awk, sort, sleep, /proc/net/dev
set -euo pipefail
IFS=$'\n\t'

ROOT="${HOME}/netwatch"
LIB="${ROOT}/bin/netwatch.sh"

# Try to source main lib if present (ok if it fails)
if [[ -f "$LIB" ]]; then
  # shellcheck disable=SC1090
  source "$LIB"
fi

# If functions/vars from the library are not available, provide safe defaults/fallbacks.
: "${SIX_HOURS:=21600}"           # 6 * 3600 seconds
: "${NET_SCAN_INTERVAL:=60}"      # sample interval (seconds)
: "${NET_EMAIL_INTERVAL:=$SIX_HOURS}"
: "${MONITOR_INTERFACES:=}"       # comma-separated list, empty => monitor all non-loopback
: "${NET_THRESHOLD_KB_S:=10240}"  # default threshold 10 MiB/s (in KiB/s)
: "${ALERT_EMAIL:=root}"

# fallback should_run: if the project lib provides it, use that — otherwise always run
if ! (type -t should_run >/dev/null 2>&1); then
  should_run() { return 0; }   # always allow
fi

# fallback log_msg: append to a project log
if ! (type -t log_msg >/dev/null 2>&1); then
  mkdir -p "${ROOT}/logs" "${ROOT}/cache" 2>/dev/null || true
  LOG_FILE_FALLBACK="${ROOT}/logs/netwatch.log"
  log_msg() {
    local msg="$1"
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %T')" "$msg" >> "$LOG_FILE_FALLBACK"
  }
fi

# fallback send_email: try mail(1) or log if not available
if ! (type -t send_email >/dev/null 2>&1); then
  send_email() {
    local subject="$1"
    local bodyfile="$2"
    if command -v mail >/dev/null 2>&1; then
      mail -s "$subject" "${ALERT_EMAIL:-root}" < "$bodyfile" 2>/dev/null || log_msg "notify: failed to mail $subject"
    else
      log_msg "notify: $subject (no mail available). See $bodyfile"
    fi
  }
fi

# Local cache dir
CACHE_DIR="${ROOT}/cache"
mkdir -p "$CACHE_DIR"

# Helper: read /proc/net/dev and print: iface rx_bytes tx_bytes rx_err tx_err
read_net_dev() {
  # Skip header lines and produce lines like:
  # eth0 12345 678 0 0
  awk 'NR>2 {
    # clean interface column (" eth0:" -> "eth0")
    gsub(/^[ \t]+|[ \t]+$/,"",$1)
    split($1,a,":"); iface=a[1]
    rx_bytes=$2
    rx_err=$4
    tx_bytes=$10
    tx_err=$12
    printf "%s %s %s %s %s\n", iface, rx_bytes, tx_bytes, rx_err, tx_err
  }' /proc/net/dev
}

# Parse MONITOR_INTERFACES into array (if empty => monitor all except lo)
IFS=',' read -r -a IF_ARR <<< "${MONITOR_INTERFACES:-}"

should_monitor_iface() {
  local ifname="$1"
  if [[ -z "${MONITOR_INTERFACES:-}" ]]; then
    [[ "$ifname" != "lo" ]] && return 0 || return 1
  fi
  for i in "${IF_ARR[@]}"; do
    [[ -z "$i" ]] && continue
    if [[ "$i" == "$ifname" ]]; then
      return 0
    fi
  done
  return 1
}

# Throttle using should_run
key="net_usage"
if ! should_run "$key" "$NET_SCAN_INTERVAL"; then
  exit 0
fi

TMP1="${CACHE_DIR}/netstat_1.txt"
TMP2="${CACHE_DIR}/netstat_2.txt"
OUT="${CACHE_DIR}/net_report.txt"

# Take two snapshots 1 second apart to estimate bytes/sec
read_net_dev > "$TMP1"
sleep 1
read_net_dev > "$TMP2"

: > "$OUT"
{
  echo "Network interface delta over 1s sample"
  echo "======================================"
  echo "sample_time: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo
} >> "$OUT"

# For each interface in TMP1, find matching line in TMP2 and compute deltas
while read -r iface rx1 tx1 rxerr1 txerr1; do
  # ensure iface is non-empty
  [[ -z "${iface:-}" ]] && continue

  # find matching line in TMP2
  # use awk to get exact-match first field
  read -r _ rx2 tx2 rxerr2 txerr2 < <(awk -v ifn="$iface" '$1==ifn { print $1, $2, $3, $4, $5; exit }' "$TMP2" || true)
  # if no matching line found, skip
  if [[ -z "${rx2:-}" && -z "${tx2:-}" ]]; then
    continue
  fi

  # Skip interfaces that we are not monitoring
  if ! should_monitor_iface "$iface"; then
    continue
  fi

  # Ensure numeric values (empty -> 0)
  rx1="${rx1:-0}"; tx1="${tx1:-0}"; rxerr1="${rxerr1:-0}"; txerr1="${txerr1:-0}"
  rx2="${rx2:-0}"; tx2="${tx2:-0}"; rxerr2="${rxerr2:-0}"; txerr2="${txerr2:-0}"

  # Compute deltas (rx2-rx1, tx2-tx1)
  drx=$(( rx2 - rx1 ))
  dtx=$(( tx2 - tx1 ))
  derr_rx=$(( rxerr2 - rxerr1 ))
  derr_tx=$(( txerr2 - txerr1 ))

  # Convert bytes/sec to KiB/sec (integer)
  drx_k=$(( drx / 1024 ))
  dtx_k=$(( dtx / 1024 ))

  printf "iface=%s rx_kB_s=%d tx_kB_s=%d rx_err_delta=%d tx_err_delta=%d\n" \
    "$iface" "$drx_k" "$dtx_k" "$derr_rx" "$derr_tx" >> "$OUT"
done < "$TMP1"

# Alerting rule: errors > 0 or bandwidth above threshold
THRESH_KB_S="${NET_THRESHOLD_KB_S:-10240}"   # default 10240 KiB/s = 10 MiB/s
ERR_TRIGGER=0
BW_TRIGGER=0

while read -r line; do
  # parse fields like: iface=eth0 rx_kB_s=12 tx_kB_s=34 rx_err_delta=0 tx_err_delta=0
  iface=$(awk -F'[ =]+' '{ for(i=1;i<=NF;i++) if($i=="iface") { print $(i+1); exit } }' <<< "$line")
  rx_k=$(awk -F'[ =]+' '{ for(i=1;i<=NF;i++) if($i=="rx_kB_s") { print $(i+1); exit } }' <<< "$line")
  tx_k=$(awk -F'[ =]+' '{ for(i=1;i<=NF;i++) if($i=="tx_kB_s") { print $(i+1); exit } }' <<< "$line")
  rx_err=$(awk -F'[ =]+' '{ for(i=1;i<=NF;i++) if($i=="rx_err_delta") { print $(i+1); exit } }' <<< "$line")
  tx_err=$(awk -F'[ =]+' '{ for(i=1;i<=NF;i++) if($i=="tx_err_delta") { print $(i+1); exit } }' <<< "$line")

  # ensure numeric defaults
  rx_k="${rx_k:-0}"; tx_k="${tx_k:-0}"
  rx_err="${rx_err:-0}"; tx_err="${tx_err:-0}"

  # convert to integers (in case)
  rx_k=$(( rx_k + 0 ))
  tx_k=$(( tx_k + 0 ))
  rx_err=$(( rx_err + 0 ))
  tx_err=$(( tx_err + 0 ))

  if (( rx_err > 0 || tx_err > 0 )); then
    log_msg "warning: network errors on ${iface:-unknown} rx_err=${rx_err} tx_err=${tx_err}"
    ERR_TRIGGER=1
  fi

  if (( rx_k >= THRESH_KB_S || tx_k >= THRESH_KB_S )); then
    log_msg "warning: high bandwidth on ${iface:-unknown} rx=${rx_k}KB/s tx=${tx_k}KB/s"
    BW_TRIGGER=1
  fi
done < "$OUT"

# If any trigger, send a single aggregated alert (throttled by should_run)
if (( ERR_TRIGGER == 1 || BW_TRIGGER == 1 )); then
  if should_run net_email_status "$NET_EMAIL_INTERVAL"; then
    if (type -t send_email >/dev/null 2>&1); then
      send_email "Warning: Network anomalies" "$OUT"
    else
      if command -v mail >/dev/null 2>&1; then
        mail -s "Warning: Network anomalies" "${ALERT_EMAIL:-root}" < "$OUT" 2>/dev/null || log_msg "notify: failed to mail network alert"
      else
        log_msg "warning: Network anomalies detected but no mail/send_email available"
      fi
    fi
  fi
fi

# Print report to stdout for inspection (and keep under cache/)
cat "$OUT"
exit 0
