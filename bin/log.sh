#!/usr/bin/env bash
# logs.sh - scan configured log files for patterns and send alert/report
# config file: config/log_patterns.conf
set -uo pipefail
IFS=$'\n\t'

ROOT="${HOME}/netwatch"
CONF="${ROOT}/config/log_patterns.conf"
CACHE="${ROOT}/cache"
mkdir -p "$CACHE"

REPORT="${CACHE}/logs_report.txt"
: > "$REPORT"

if [[ ! -f "$CONF" ]]; then
  echo "No ${CONF} found. Create one with lines: path|regex|label|severity" >&2
  exit 0
fi

# pattern file format (per-line):
# /var/log/nginx/error.log|error|nginx_error|CRITICAL
# /var/log/syslog|warn|sys_warn|WARNING
while IFS= read -r ln || [[ -n "$ln" ]]; do
  ln="${ln##*( )}"; ln="${ln%%*( )}"
  [[ -z "$ln" || "${ln:0:1}" == "#" ]] && continue
  path=$(awk -F'|' '{print $1}' <<<"$ln")
  regex=$(awk -F'|' '{print $2}' <<<"$ln")
  label=$(awk -F'|' '{print $3}' <<<"$ln")
  severity=$(awk -F'|' '{print $4}' <<<"$ln")

  if [[ ! -f "$path" ]]; then
    echo "WARN: file not found: $path" >> "$REPORT"
    continue
  fi

  # check last 500 lines for matches
  matches=$(tail -n 500 "$path" | grep -E -n -- "$regex" || true)
  if [[ -n "$matches" ]]; then
    echo "===== $label ($severity) - $path =====" >> "$REPORT"
    echo "$matches" >> "$REPORT"
    echo >> "$REPORT"
  fi
done < "$CONF"

if [[ -s "$REPORT" ]]; then
  # throttle by 1 hour by default
  if type -t should_run >/dev/null 2>&1 && should_run logs_email 3600; then
    if type -t send_email >/dev/null 2>&1; then
      send_email "Log Alerts" "$REPORT"
    elif command -v mail >/dev/null 2>&1; then
      mail -s "Log Alerts" "${ALERT_EMAIL:-root}" < "$REPORT" || true
    fi
  fi
  cat "$REPORT"
else
  echo "No log matches found."
fi
exit 0
