#!/usr/bin/env bash
# validate_config.sh - quick checks for common typos/missing vars
CONF="${HOME}/netwatch/config/netwatch.conf"
if [[ ! -f "$CONF" ]]; then
  echo "No config found at $CONF" >&2
  exit 1
fi
echo "Validating $CONF..."
# Check for required thresholds
required=(CPU_SCAN_INTERVAL MEM_SCAN_INTERVAL DISK_SCAN_INTERVAL ALERT_EMAIL WARNING_CPU CRITICAL_CPU WARNING_MEM CRITICAL_MEM WARNING_DISK CRITICAL_DISK)
missing=()
for v in "${required[@]}"; do
  if ! grep -q -E "^\s*${v}\s*=" "$CONF"; then
    missing+=("$v")
  fi
done
if (( ${#missing[@]} )); then
  echo "WARNING: The following recommended variables are missing from config:"
  for m in "${missing[@]}"; do echo "  - $m"; done
else
  echo "All recommended variables present."
fi

# detect suspicious names (common typos)
if grep -nE 'CPU_WARN|MEM_WARN|DISK_WARN' "$CONF" >/dev/null 2>&1; then
  echo "Note: config uses CPU_WARN/MEM_WARN etc. The script maps these to WARNING_* variables but consider renaming to WARNING_CPU/WARNING_MEM for clarity."
fi

echo "Done."
