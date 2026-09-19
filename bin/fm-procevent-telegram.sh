#!/usr/bin/env bash
# Telegram adapter for the generic process-to-event runner.
#
# Usage:
#   fm-procevent-telegram.sh silent <result-file>
#   fm-procevent-telegram.sh terminal <result-file>
#   fm-procevent-telegram.sh autohandle <source-id> <sequence> <result-file>
#   fm-procevent-telegram.sh classify <result-file>
#
# The Telegram listener (`fm-telegram.sh listen`) is a long-polling loop that
# already appends `check: telegram <update_id>` wakes itself and advances the
# durable offset. The runner's only job is to keep that listener alive; any
# captured result is therefore a routine no-op from the runner's perspective,
# except the listener's final failure line, which is announced so a dead
# channel is never swallowed. The real inbound wakes come directly from the
# listener.
#
# This adapter owns only Telegram-specific lifecycle decisions. Ownership,
# durable capture, publication, and restart recovery belong to bin/fm-procevent.sh.
set -u

usage() {
  cat <<'EOF'
fm-procevent-telegram.sh silent <result-file>
fm-procevent-telegram.sh terminal <result-file>
fm-procevent-telegram.sh autohandle <source-id> <sequence> <result-file>
fm-procevent-telegram.sh classify <result-file>
EOF
}

# A result is silent unless it carries the listener's final failure line, so a
# dead listener is announced while routine output stays quiet.
cmd_silent() {
  local file=${1-}
  [ -n "$file" ] || { usage >&2; exit 2; }
  [ -f "$file" ] || return 0
  ! grep -q 'listen exiting after' "$file"
}

# The listener never terminates voluntarily; the runner keeps it restarted.
cmd_terminal() {
  return 1
}

# Nothing to apply; the listener already durably queued its own wakes.
cmd_autohandle() {
  return 0
}

# Print a one-word classification for a handler that inspects the result.
cmd_classify() {
  local file=${1-}
  [ -n "$file" ] || { usage >&2; exit 2; }
  [ -f "$file" ] || { printf 'error: result file does not exist: %s\n' "$file" >&2; exit 2; }
  if [ -s "$file" ]; then
    printf 'error\n'
  else
    printf 'listening\n'
  fi
  return 0
}

case "${1-}" in
  silent) shift; cmd_silent "$@" ;;
  terminal) shift; cmd_terminal "$@" ;;
  autohandle) shift; cmd_autohandle "$@" ;;
  classify) shift; cmd_classify "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
