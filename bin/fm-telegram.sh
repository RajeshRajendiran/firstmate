#!/usr/bin/env bash
# fm-telegram.sh - Telegram plane for private captain chat.
#
# Receives messages from a Telegram bot's private chat with the captain and
# sends replies to the same chat. This is a reversible-work-only channel:
# every surfaced message becomes a notification firstmate reads before
# deciding, and merges, destructive, or security-sensitive asks still need
# terminal confirmation.
#
# Subcommands:
#   poll                 Long-poll getUpdates (no webhook), keep only messages
#                        whose chat id equals FM_TELEGRAM_CAPTAIN_CHAT_ID,
#                        stash each accepted message under state/telegram/,
#                        and append exactly one `check: telegram <update_id>`
#                        wake per accepted message. Advances the durable
#                        offset only after the record and wake are durable.
#                        Bounds wakes per run like the mail plane.
#   listen               Run poll in a tight loop for near-instant delivery.
#                        The loop is meant to be supervised as a process-event
#                        source; do not run two consumers for the same bot.
#   send <text | ->      Send one or more messages to the captain chat id,
#                        splitting at 4,096 characters on line boundaries and
#                        respecting the one-message-per-second limit. Reports
#                        delivered, ambiguous, or not-delivered for each chunk.
#                        Text is sent as Telegram HTML: **bold** and `code` render,
#                        everything else is escaped, split chunks stay well formed,
#                        and a markup rejection resends unformatted (printed as fallback).
#   status               Print configuration presence (never the token) and
#                        the last offset. No network call, no wake.
#
# Configuration is read from the home's gitignored .env, with environment
# values winning for direct invocations (same contract as Relay and mail).
# Required values:
#   FM_TELEGRAM_BOT_TOKEN=<bot token from BotFather>
#   FM_TELEGRAM_CAPTAIN_CHAT_ID=<captain's chat id>
# Optional values:
#   FM_TELEGRAM_API_URL_PREFIX (default https://api.telegram.org)
#   FM_TELEGRAM_POLL_TIMEOUT (default 30 seconds)
#   FM_TELEGRAM_SEND_TIMEOUT (default 30 seconds)
#   FM_TELEGRAM_SEND_RATE_LIMIT (default 1 second between chunks)
#   FM_TELEGRAM_POLL_MAX_WAKES (default 20, valid 1..200)
# FM_HOME falls back to the repo root when unset. The engine is
# bin/fm-telegram.py; see docs/configuration.md "Telegram plane" for the
# schema and state-file contract.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-}"
if [ -z "$FM_HOME" ]; then
  FM_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
ENV_FILE="$FM_HOME/.env"

# Load the home .env for keys not already set. Tolerates a leading "export ",
# surrounding whitespace, one layer of matching quotes, comments, and blank
# lines, exactly like the mail and Relay contracts.
if [ -f "$ENV_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in
      ''|\#*) continue ;;
      export\ *) line="${line#export }" ;;
    esac
    case "$line" in
      *=*) ;;
      *) continue ;;
    esac
    key="${line%%=*}"
    key="${key#"${key%%[![:space:]]*}"}"
    val="${line#*=}"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    case "$val" in
      \"*) val=${val#\"}; val=${val%\"} ;;
      \'*) val=${val#\'}; val=${val%\'} ;;
    esac
    if [ -n "$key" ] && [ -z "${!key:-}" ]; then
      export "$key=$val"
    fi
  done < "$ENV_FILE"
fi

if [ -z "${FM_TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${FM_TELEGRAM_CAPTAIN_CHAT_ID:-}" ]; then
  printf "fm-telegram: missing required \$FM_HOME/.env values: FM_TELEGRAM_BOT_TOKEN and FM_TELEGRAM_CAPTAIN_CHAT_ID\n" >&2
  exit 1
fi

CHAT_ID="$FM_TELEGRAM_CAPTAIN_CHAT_ID"
if ! printf '%s\n' "$CHAT_ID" | grep -Eq '^-?[0-9]+$'; then
  printf 'fm-telegram: FM_TELEGRAM_CAPTAIN_CHAT_ID must be an integer, got: %s\n' "$CHAT_ID" >&2
  exit 1
fi

API_PREFIX="${FM_TELEGRAM_API_URL_PREFIX:-https://api.telegram.org}"
POLL_TIMEOUT="${FM_TELEGRAM_POLL_TIMEOUT:-30}"
SEND_TIMEOUT="${FM_TELEGRAM_SEND_TIMEOUT:-30}"
SEND_RATE_LIMIT="${FM_TELEGRAM_SEND_RATE_LIMIT:-1}"
POLL_MAX_WAKES="${FM_TELEGRAM_POLL_MAX_WAKES:-20}"

case "$POLL_TIMEOUT" in
  ''|*[!0-9]*|0) POLL_TIMEOUT=30 ;;
esac
case "$SEND_TIMEOUT" in
  ''|*[!0-9]*|0) SEND_TIMEOUT=30 ;;
esac
# Rate limit is a positive integer number of seconds.
case "$SEND_RATE_LIMIT" in
  ''|*[!0-9]*) SEND_RATE_LIMIT=1 ;;
esac
case "$POLL_MAX_WAKES" in
  ''|*[!0-9]*|0) POLL_MAX_WAKES=20 ;;
esac
if [ "$POLL_MAX_WAKES" -gt 200 ]; then
  POLL_MAX_WAKES=200
fi

PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then
  printf 'fm-telegram: python3 required\n' >&2
  exit 1
fi
PY_BIN="$SCRIPT_DIR/fm-telegram.py"
if [ ! -f "$PY_BIN" ]; then
  printf 'fm-telegram: %s missing\n' "$PY_BIN" >&2
  exit 1
fi

STATE_DIR="$FM_HOME/state"
mkdir -p "$STATE_DIR"
chmod 0700 "$STATE_DIR"
mkdir -p "$STATE_DIR/telegram"
chmod 0700 "$STATE_DIR/telegram"

OFFSET_FILE="$STATE_DIR/.telegram-offset"
WOKEN_FILE="$STATE_DIR/.telegram-woken"
STATS_FILE="$STATE_DIR/.telegram-stats"
LOCK_FILE="$STATE_DIR/.telegram-offset.lock"

export FM_TELEGRAM_BOT_TOKEN FM_TELEGRAM_CAPTAIN_CHAT_ID
export FM_TELEGRAM_API_URL_PREFIX="$API_PREFIX"
export FM_TELEGRAM_POLL_TIMEOUT="$POLL_TIMEOUT"
export FM_TELEGRAM_SEND_TIMEOUT="$SEND_TIMEOUT"
export FM_TELEGRAM_SEND_RATE_LIMIT="$SEND_RATE_LIMIT"

usage() {
  cat <<'EOF'
fm-telegram.sh poll
fm-telegram.sh listen
fm-telegram.sh send <text | ->
fm-telegram.sh status
EOF
}

# Write content atomically to path with mode 0600.
telegram_atomic_write() {
  local path=$1 content=$2 tmp
  tmp="$(mktemp "$path.tmp.XXXXXX")" || return 1
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  printf '%s\n' "$content" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$path" || { rm -f -- "$tmp"; return 1; }
  return 0
}

# Write stats atomically with two prefixed lines.
telegram_write_stats() {
  local accepted=$1 dropped=$2 tmp
  tmp="$(mktemp "$STATS_FILE.tmp.XXXXXX")" || return 1
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  printf 'accepted=%s\ndropped=%s\n' "$accepted" "$dropped" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$STATS_FILE" || { rm -f -- "$tmp"; return 1; }
  return 0
}

# Read the durable offset, defaulting to 0.
telegram_read_offset() {
  if [ -f "$OFFSET_FILE" ]; then
    cat "$OFFSET_FILE" 2>/dev/null || printf '0\n'
  else
    printf '0\n'
  fi
}

# Read stats as two lines: accepted then dropped.
telegram_read_stats() {
  local line accepted=0 dropped=0
  if [ -f "$STATS_FILE" ]; then
    while IFS= read -r line; do
      case "$line" in
        accepted=*) accepted="${line#accepted=}" ;;
        dropped=*) dropped="${line#dropped=}" ;;
      esac
    done < "$STATS_FILE"
  fi
  printf 'accepted=%s\ndropped=%s\n' "$accepted" "$dropped"
}

# True when the accepted message's wake is already durable: in the local
# emission journal or still queued for the drain.
telegram_is_woken() {
  local id=$1
  if [ -f "$WOKEN_FILE" ] && grep -Fqx "$id" "$WOKEN_FILE"; then
    return 0
  fi
  if [ -s "$FM_WAKE_QUEUE" ] && grep -q $'\tcheck\ttelegram:'"$id" "$FM_WAKE_QUEUE"; then
    return 0
  fi
  return 1
}

# Reconcile a poll interrupted between its durable writes. The offset is the
# maximum of the stored cursor, the local emission journal, and any queued
# telegram wake keys, so a recovered wake is never re-fetched and a fetch
# killed before the offset write is healed from the journal.
telegram_heal_offset() {
  local offset=$1 id new_offset line key
  new_offset=$offset
  if [ -s "$WOKEN_FILE" ]; then
    while IFS= read -r id || [ -n "$id" ]; do
      [ -n "$id" ] || continue
      case "$id" in
        *[!0-9]*) continue ;;
      esac
      [ "$id" -gt "$new_offset" ] && new_offset=$id
    done < "$WOKEN_FILE"
  fi
  if [ -s "$FM_WAKE_QUEUE" ]; then
    while IFS= read -r key; do
      id="${key#telegram:}"
      [ "$id" = "$key" ] && continue
      case "$id" in
        *[!0-9]*) continue ;;
      esac
      [ "$id" -gt "$new_offset" ] && new_offset=$id
    done < <(fm_wake_queued_keys check 2>/dev/null || true)
  fi
  if [ "$new_offset" -ne "$offset" ]; then
    telegram_atomic_write "$OFFSET_FILE" "$new_offset" || return 1
    telegram_prune_woken "$new_offset" || true
  fi
  printf '%s\n' "$new_offset"
  return 0
}

# Drop journal entries no longer ahead of the offset.
telegram_prune_woken() {
  local boundary=$1 tmp
  [ -s "$WOKEN_FILE" ] || return 0
  tmp="$(mktemp "$WOKEN_FILE.prune.XXXXXX")" || return 1
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  if ! awk -v b="$boundary" '$1 > b { print }' "$WOKEN_FILE" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  mv -f -- "$tmp" "$WOKEN_FILE" || { rm -f -- "$tmp"; return 1; }
  return 0
}

# Append one check wake and its journal entry under the held queue lock.
telegram_wake_for() {
  local id=$1 summary=$2 lib="$SCRIPT_DIR/fm-wake-lib.sh" tmp
  if [ ! -f "$lib" ]; then
    printf 'fm-telegram: %s missing; cannot wake\n' "$lib" >&2
    return 1
  fi
  # shellcheck source=bin/fm-wake-lib.sh
  # shellcheck disable=SC1091
  . "$lib"
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 1
  if fm_wake_append_locked check "telegram:$id" "check: telegram $id - $summary"; then
    if printf '%s\n' "$id" >> "$WOKEN_FILE"; then
      fm_lock_release "$FM_WAKE_QUEUE_LOCK"
      return 0
    fi
    # Journal append failed: roll back the queued wake so it cannot be
    # acknowledged without durable evidence.
    tmp="$(mktemp "$FM_WAKE_QUEUE.rollback.XXXXXX")" || {
      fm_lock_release "$FM_WAKE_QUEUE_LOCK"
      return 1
    }
    if awk -F '\t' -v key="$id" '
      NF >= 5 && $3 == "check" && $4 == "telegram:"key { next }
      { print }
    ' "$FM_WAKE_QUEUE" > "$tmp"; then
      chmod 0600 "$tmp" 2>/dev/null || true
      mv -f -- "$tmp" "$FM_WAKE_QUEUE" 2>/dev/null || rm -f -- "$tmp"
    else
      rm -f -- "$tmp"
    fi
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 1
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return 1
}

# Run the python engine for a poll with the given offset.
telegram_run_poll() {
  local offset=$1
  FM_TELEGRAM_OFFSET="$offset" "$PY" "$PY_BIN" poll
}

# Run the python engine to send text from a file.
telegram_run_send() {
  local text_file=$1
  "$PY" "$PY_BIN" send "$text_file"
}

telegram_poll() {
  local quiet=${1:-0}
  local offset new_offset accepted=0 dropped=0 woke=0
  local poll_out poll_err line kind json_line update_id summary
  local record_tmp stats_accepted stats_dropped
  if [ ! -f "$SCRIPT_DIR/fm-wake-lib.sh" ]; then
    printf 'fm-telegram: %s/fm-wake-lib.sh missing; cannot poll\n' "$SCRIPT_DIR" >&2
    return 1
  fi
  # shellcheck source=bin/fm-wake-lib.sh
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  fm_lock_acquire_wait "$LOCK_FILE" || return 1
  offset="$(telegram_read_offset)"
  case "$offset" in
    ''|*[!0-9]*) offset=0 ;;
  esac
  new_offset="$(telegram_heal_offset "$offset")" || {
    fm_lock_release "$LOCK_FILE"
    return 1
  }
  offset=$new_offset

  poll_out="$(mktemp)" || { fm_lock_release "$LOCK_FILE"; return 1; }
  poll_err="$(mktemp)" || { rm -f -- "$poll_out"; fm_lock_release "$LOCK_FILE"; return 1; }
  if ! telegram_run_poll "$offset" > "$poll_out" 2> "$poll_err"; then
    cat "$poll_err" >&2
    rm -f -- "$poll_out" "$poll_err"
    fm_lock_release "$LOCK_FILE"
    return 1
  fi
  rm -f -- "$poll_err"

  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    kind="${line:0:1}"
    case "$kind" in
      D)
        update_id="${line#D }"
        case "$update_id" in
          ''|*[!0-9]*) continue ;;
        esac
        [ "$update_id" -gt "$new_offset" ] && new_offset=$update_id
        dropped=$((dropped + 1))
        ;;
      A)
        json_line="${line#A }"
        update_id="$(printf '%s\n' "$json_line" | "$PY" -c 'import sys, json; print(json.loads(sys.stdin.read())["update_id"])')"
        summary="$(printf '%s\n' "$json_line" | "$PY" -c 'import sys, json; print(json.loads(sys.stdin.read())["summary"])')"
        if telegram_is_woken "$update_id"; then
          [ "$update_id" -gt "$new_offset" ] && new_offset=$update_id
          accepted=$((accepted + 1))
          continue
        fi
        if [ "$woke" -ge "$POLL_MAX_WAKES" ]; then
          break
        fi
        record_tmp="$(mktemp "$STATE_DIR/telegram/$update_id.json.tmp.XXXXXX")" || {
          printf 'fm-telegram: cannot create record temp for %s\n' "$update_id" >&2
          break
        }
        chmod 0600 "$record_tmp"
        if ! printf '%s\n' "$json_line" > "$record_tmp"; then
          rm -f -- "$record_tmp"
          break
        fi
        if ! mv -f -- "$record_tmp" "$STATE_DIR/telegram/$update_id.json"; then
          rm -f -- "$record_tmp"
          printf 'fm-telegram: could not commit record for %s\n' "$update_id" >&2
          break
        fi
        if telegram_wake_for "$update_id" "$summary"; then
          woke=$((woke + 1))
          accepted=$((accepted + 1))
          [ "$update_id" -gt "$new_offset" ] && new_offset=$update_id
          printf 'fm-telegram: woke for %s\n' "$update_id"
        else
          printf 'fm-telegram: wake failed for %s\n' "$update_id" >&2
          break
        fi
        ;;
      *)
        continue
        ;;
    esac
  done < "$poll_out"
  rm -f -- "$poll_out"

  if [ "$new_offset" -ne "$offset" ]; then
    telegram_atomic_write "$OFFSET_FILE" "$new_offset" || {
      fm_lock_release "$LOCK_FILE"
      return 1
    }
  fi
  if [ "$accepted" -gt 0 ] || [ "$dropped" -gt 0 ]; then
    stats_accepted=0
    stats_dropped=0
    while IFS= read -r line; do
      case "$line" in
        accepted=*) stats_accepted="${line#accepted=}" ;;
        dropped=*) stats_dropped="${line#dropped=}" ;;
      esac
    done < <(telegram_read_stats)
    case "$stats_accepted" in ''|*[!0-9]*) stats_accepted=0 ;; esac
    case "$stats_dropped" in ''|*[!0-9]*) stats_dropped=0 ;; esac
    stats_accepted=$((stats_accepted + accepted))
    stats_dropped=$((stats_dropped + dropped))
    telegram_write_stats "$stats_accepted" "$stats_dropped" || {
      fm_lock_release "$LOCK_FILE"
      return 1
    }
  fi
  fm_lock_release "$LOCK_FILE"
  if [ "$woke" -eq 0 ] && [ "$quiet" -eq 0 ]; then
    printf 'fm-telegram: no new messages\n'
  fi
  return 0
}

# Long-polling listener: repeatedly run poll. Each poll itself long-polls the
# Telegram server, so this loop delivers within seconds when the server has a
# message. It is intended to run under the process-event runner, which
# restarts it if it exits. Failures back off so a transient API error does
# not spam the runner with restarts.
telegram_listen() {
  local quiet=1 failures=0 max_failures=5 delay=5 max_delay=30
  while :; do
    if telegram_poll "$quiet"; then
      failures=0
      delay=5
      continue
    fi
    failures=$((failures + 1))
    if [ "$failures" -ge "$max_failures" ]; then
      printf 'fm-telegram: listen exiting after %d consecutive poll failures\n' "$failures" >&2
      return 1
    fi
    printf 'fm-telegram: poll failed (%d/%d), retrying in %ds\n' "$failures" "$max_failures" "$delay" >&2
    sleep "$delay"
    delay=$((delay * 2))
    [ "$delay" -gt "$max_delay" ] && delay=$max_delay
  done
}

telegram_send() {
  local text_arg text_file
  text_arg="${2:-}"
  if [ -z "$text_arg" ]; then
    usage
    exit 1
  fi
  text_file="$(mktemp)" || return 1
  if [ "$text_arg" = "-" ]; then
    cat > "$text_file"
  else
    printf '%s' "$text_arg" > "$text_file"
  fi
  local rc=0
  telegram_run_send "$text_file" || rc=$?
  rm -f -- "$text_file"
  return "$rc"
}

telegram_status() {
  local offset accepted dropped line
  offset="$(telegram_read_offset)"
  accepted=0
  dropped=0
  while IFS= read -r line; do
    case "$line" in
      accepted=*) accepted="${line#accepted=}" ;;
      dropped=*) dropped="${line#dropped=}" ;;
    esac
  done < <(telegram_read_stats)
  printf 'telegram bot: configured\n'
  printf 'captain chat id: %s\n' "$CHAT_ID"
  printf 'last offset: %s\n' "$offset"
  printf 'accepted: %s\n' "$accepted"
  printf 'dropped: %s\n' "$dropped"
}

case "${1:-}" in
  poll)
    telegram_poll
    ;;
  listen)
    telegram_listen
    ;;
  send)
    telegram_send "$@"
    ;;
  status)
    telegram_status
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage
    exit 1
    ;;
esac
