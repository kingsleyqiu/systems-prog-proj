#!/usr/bin/env bash
# notify.sh - small helper to send notifications (webhook or mail)
set -eu -o pipefail
ROOT="${HOME}/netwatch"
. "${ROOT}/bin/netwatch.sh" 2>/dev/null || true

# Usage: notify_send <subject> <body-file>
notify_send() {
  local subject="$1"
  local bodyfile="$2"

  # webhook JSON POST if NOTIFIER_WEBHOOK is set (curl must exist)
  if [[ -n "${NOTIFIER_WEBHOOK:-}" ]] && command -v curl >/dev/null 2>&1; then
    payload=$(jq -n --arg s "$subject" --arg b "$(sed ':a;N;$!ba;s/"/\\"/g' "$bodyfile")" '{text: ($s + "\n\n" + $b)}' 2>/dev/null || true)
    if [[ -n "$payload" ]]; then
      curl -s -X POST -H 'Content-Type: application/json' -d "$payload" "$NOTIFIER_WEBHOOK" >/dev/null 2>&1 || true
    else
      # fallback: post plain text
      curl -s -X POST --data-urlencode "payload=$subject\n$(cat "$bodyfile")" "$NOTIFIER_WEBHOOK" >/dev/null 2>&1 || true
    fi
  fi

  # prefer send_email() from netwatch library
  if type -t send_email >/dev/null 2>&1; then
    send_email "$subject" "$bodyfile"
    return
  fi

  # fallback to mail
  if command -v mail >/dev/null 2>&1; then
    mail -s "$subject" "${ALERT_EMAIL:-root}" < "$bodyfile" || true
  else
    # last fallback: write to logfile
    log_msg "notify: $subject (no mail/curl available). See $bodyfile"
  fi
}
