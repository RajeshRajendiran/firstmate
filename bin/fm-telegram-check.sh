#!/usr/bin/env bash
# fm-telegram-check.sh - recurring Telegram poll as a standing watcher check,
# plus a near-instant listen path registered as a process-event source.
#
# Usage:
#   fm-telegram-check.sh [check]
#   fm-telegram-check.sh arm
#   fm-telegram-check.sh disarm
#   fm-telegram-check.sh listen-arm
#   fm-telegram-check.sh listen-disarm
#   fm-telegram-check.sh --help
#
# `check` runs the Telegram poll from this home on the watcher's normal
# FM_CHECK_INTERVAL cadence. It composes with the existing watcher state-check
# contract: a printed line becomes a `check:` wake so firstmate can drain the
# durable `check: telegram <update_id>` rows the poll already queued.
#
# `arm` writes state/telegram.check.sh and binds its bytes with
# fm-check-register.sh, so the watcher dispatches it on its normal cadence with
# no new process.
# `disarm` removes the shim, its trust binding, and the report record.
#
# `listen-arm` registers `fm-telegram.sh listen` as a process-event source for
# near-instant delivery, then tells you to run `fm-procevent.sh reconcile` so
# the runner starts the listener. Only one of the standing check or the
# listen source may be armed for a home at a time, because Telegram delivers
# updates to one long-polling consumer per bot token.
# `listen-disarm` retires the process-event source.
#
# Telegram configuration is read from the home's own .env by the poll, so
# arming needs no configuration of its own. A home armed before its .env has
# FM_TELEGRAM_BOT_TOKEN and FM_TELEGRAM_CAPTAIN_CHAT_ID is reported once for
# the missing value until the .env is fixed.
#
# Reporting keeps state/.telegram-check as the news key, but prints whenever
# the poll is not a proven no-op. A proven no-op is a repeated identical line,
# not a timeout, with no publication evidence. Publication evidence is a
# timeout, fail-closed diagnostics, a queued telegram: check key, or growth of
# state/.telegram-woken. Same-line silence is only for a proven no-op.
#
# The poll must finish inside the watcher's per-check bound
# (FM_CHECK_TIMEOUT, default 30). The internal budget
# FM_TELEGRAM_CHECK_BUDGET (default 15, valid 5..25) is cut down to whatever
# fits inside that bound.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
RECORD="$STATE/.telegram-check"
CHECK_ID=telegram
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
TELEGRAM_BIN="$SCRIPT_DIR/fm-telegram.sh"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
PROCEVENT_BIN="$SCRIPT_DIR/fm-procevent.sh"
RECORD_SCHEMA=fm-telegram-check-v1
MAX_LINE=240
LISTEN_SOURCE_ID=telegram-listen
LISTEN_ADAPTER=telegram

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-telegram-check.sh [check]       run the Telegram poll; wake line unless the poll is a proven no-op
  fm-telegram-check.sh arm           write and register state/telegram.check.sh
  fm-telegram-check.sh disarm        remove the check shim, its trust binding, and the report record
  fm-telegram-check.sh listen-arm    register fm-telegram.sh listen as a process-event source
  fm-telegram-check.sh listen-disarm retire the process-event source
  fm-telegram-check.sh --help        print this help

Telegram configuration (FM_TELEGRAM_BOT_TOKEN, FM_TELEGRAM_CAPTAIN_CHAT_ID) is
read from <FM_HOME>/.env by fm-telegram.sh.
See docs/configuration.md "Telegram plane" for the schema.
EOF
}

die_usage() {
  printf 'fm-telegram-check: %s\n' "$1" >&2
  usage >&2
  exit 2
}

record_epoch_now() {
  case "${FM_TELEGRAM_CHECK_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_TELEGRAM_CHECK_NOW" ;;
  esac
}

CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT" in
  ''|*[!0-9]*|0) CHECK_TIMEOUT=30 ;;
esac

BUDGET_SECS=${FM_TELEGRAM_CHECK_BUDGET:-15}
case "$BUDGET_SECS" in
  ''|*[!0-9]*|0)
    printf 'fm-telegram-check: FM_TELEGRAM_CHECK_BUDGET must be a whole number from 5 to 25\n' >&2
    exit 2
    ;;
esac
if [ "$BUDGET_SECS" -lt 5 ] || [ "$BUDGET_SECS" -gt 25 ]; then
  printf 'fm-telegram-check: FM_TELEGRAM_CHECK_BUDGET must be a whole number from 5 to 25\n' >&2
  exit 2
fi

BUDGET_MAX=$((CHECK_TIMEOUT - 3))
[ "$BUDGET_MAX" -ge 1 ] || BUDGET_MAX=1
if [ "$BUDGET_SECS" -gt "$BUDGET_MAX" ]; then
  BUDGET_SECS=$BUDGET_MAX
fi

# True when the listen process-event source is currently registered.
listen_is_registered() {
  [ -f "$STATE/procevent/$LISTEN_SOURCE_ID.source" ] && [ ! -L "$STATE/procevent/$LISTEN_SOURCE_ID.source" ]
}

# One poll summary, built only from the poll's own combined output.
poll_summary() {
  local rc=$1 out=$2 line
  line=$(printf '%s\n' "$out" | sed -n '/^fm-telegram: woke for /d; s/^fm-telegram: //p' | sed -n '1p')
  if [ -z "$line" ]; then
    line=$(printf '%s\n' "$out" | sed -n '/^fm-telegram: woke for /d; /^$/d; p' | sed -n '1p')
  fi
  if [ -z "$line" ]; then
    line="poll failed (rc=$rc)"
  fi
  printf '%s\n' "$line"
}

record_read() {
  local line first=1
  RECORD_REPORTED=
  [ -f "$RECORD" ] || return 0
  while IFS= read -r line; do
    if [ "$first" = 1 ]; then
      first=0
      [ "$line" = "$RECORD_SCHEMA" ] || return 0
      continue
    fi
    case "$line" in
      reported=*) RECORD_REPORTED=${line#reported=} ;;
    esac
  done < "$RECORD"
  return 0
}

record_write() {
  local reported=$1 tmp
  tmp=$(mktemp "$RECORD.XXXXXX" 2>/dev/null) || return 1
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  {
    printf '%s\n' "$RECORD_SCHEMA"
    printf 'epoch=%s\n' "$(record_epoch_now)"
    printf 'reported=%s\n' "$reported"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$RECORD" || { rm -f -- "$tmp"; return 1; }
  return 0
}

# True when this poll has publication evidence, so a repeated diagnostic is
# not a proven no-op.
poll_has_publication_evidence() {
  local rc=${1:-0} out=$2 woken_before=$3
  [ "$rc" -eq 124 ] && return 0
  if [ -n "$out" ] && printf '%s\n' "$out" | grep -E \
    '^fm-telegram: woke for |the wake stays queued|could not clear retry for recovered' >/dev/null
  then
    return 0
  fi
  if [ -s "$STATE/.wake-queue" ] && grep -q $'\tcheck\ttelegram:' "$STATE/.wake-queue"; then
    return 0
  fi
  if [ -f "$STATE/.telegram-woken" ]; then
    if [ -z "$woken_before" ] || [ ! -f "$woken_before" ] \
      || ! cmp -s "$woken_before" "$STATE/.telegram-woken"; then
      return 0
    fi
  fi
  return 1
}

action_check() {
  local out rc=0 line woken_before queued=0
  mkdir -p "$STATE" || return 1
  if listen_is_registered; then
    # The listen source is the active consumer; the standing check would race
    # with its long-poll and could miss updates. Stay silent.
    return 0
  fi
  woken_before=$(mktemp) || woken_before=
  if [ -n "$woken_before" ]; then
    if [ -f "$STATE/.telegram-woken" ]; then
      cp "$STATE/.telegram-woken" "$woken_before" 2>/dev/null || : > "$woken_before"
    else
      : > "$woken_before"
    fi
  fi
  if [ ! -x "$TELEGRAM_BIN" ]; then
    line="fm-telegram.sh is missing next to this check ($TELEGRAM_BIN)"
  else
    out=$(fm_run_timed "$BUDGET_SECS" "$TELEGRAM_BIN" poll 2>&1) || rc=$?
    if [ "${rc:-0}" -eq 124 ]; then
      line="poll did not finish within the ${BUDGET_SECS}s budget"
    elif [ "${rc:-0}" -ne 0 ]; then
      line=$(poll_summary "$rc" "$out")
    elif printf '%s\n' "$out" | grep '^fm-telegram: woke for ' >/dev/null; then
      line=$(printf '%s\n' "$out" | grep '^fm-telegram: woke for ' | tail -n 1 | sed 's/^fm-telegram: /new message: /')
    else
      line=
    fi
  fi
  record_read
  if poll_has_publication_evidence "${rc:-0}" "${out:-}" "$woken_before"; then
    queued=1
  fi
  [ -n "$woken_before" ] && rm -f -- "$woken_before"
  if [ -n "$line" ] && { [ "$line" != "$RECORD_REPORTED" ] || [ "$queued" -eq 1 ]; }; then
    fm_cap_line_var "telegram: $line" "$MAX_LINE"
    printf '%s\n' "$FM_LINE_CAP_LINE"
  fi
  record_write "$line" || true
  return 0
}

shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-telegram-check.sh - Telegram poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-telegram-check.sh") check"
}

SHIM_WRITE_TMP=

shim_write() {
  local want=$1 device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-telegram-check.XXXXXX" 2>/dev/null) || return 1
  SHIM_WRITE_TMP=$tmp
  if ! printf '%s\n' "$want" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  SHIM_WRITE_TMP=
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

shim_backup() {
  local device tmp
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-telegram-check.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$CHECK_SHIM" > "$tmp" 2>/dev/null \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

ARM_BACKUP=

arm_rollback() {
  [ -z "$SHIM_WRITE_TMP" ] || rm -f -- "$SHIM_WRITE_TMP"
  SHIM_WRITE_TMP=
  if [ -n "$ARM_BACKUP" ]; then
    mv -f -- "$ARM_BACKUP" "$CHECK_SHIM" 2>/dev/null || rm -f -- "$ARM_BACKUP"
    ARM_BACKUP=
    if fm_custom_check_registered "$STATE" "$CHECK_ID"; then
      return 0
    fi
  fi
  rm -f -- "$CHECK_SHIM"
}

arm_interrupted() {
  arm_rollback
  printf 'fm-telegram-check: arming was interrupted, so state/%s.check.sh is not armed\n' "$CHECK_ID" >&2
  exit 1
}

action_arm() {
  local want home
  if [ ! -x "$TELEGRAM_BIN" ]; then
    printf 'fm-telegram-check: the Telegram plane is missing at %s; cannot arm\n' "$TELEGRAM_BIN" >&2
    return 1
  fi
  if listen_is_registered; then
    printf 'fm-telegram-check: the listen source is active; disarm it before arming the standing check\n' >&2
    return 1
  fi
  mkdir -p "$STATE" || return 1
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-telegram-check: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac
  want=$(shim_content "$home")
  ARM_BACKUP=
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    ARM_BACKUP=$(shim_backup) || {
      printf 'fm-telegram-check: could not save the existing %s\n' "$CHECK_SHIM" >&2
      return 1
    }
  fi
  trap arm_interrupted HUP INT TERM
  if ! shim_write "$want"; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-telegram-check: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-telegram-check: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  trap - HUP INT TERM
  [ -z "$ARM_BACKUP" ] || rm -f -- "$ARM_BACKUP"
  ARM_BACKUP=
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

action_disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

action_listen_arm() {
  local home
  if [ ! -x "$TELEGRAM_BIN" ]; then
    printf 'fm-telegram-check: the Telegram plane is missing at %s; cannot listen\n' "$TELEGRAM_BIN" >&2
    return 1
  fi
  if [ -e "$CHECK_SHIM" ] || [ -L "$CHECK_SHIM" ]; then
    printf 'fm-telegram-check: the standing check is armed; disarm it before arming listen\n' >&2
    return 1
  fi
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-telegram-check: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac
  if ! "$PROCEVENT_BIN" register "$LISTEN_ADAPTER" "$LISTEN_SOURCE_ID" \
    -- "$TELEGRAM_BIN" listen; then
    return 1
  fi
  printf 'listen armed: %s (%s)\n' "$LISTEN_SOURCE_ID" "$LISTEN_ADAPTER"
  printf 'start: %s reconcile\n' "$PROCEVENT_BIN"
  return 0
}

action_listen_disarm() {
  "$PROCEVENT_BIN" retire "$LISTEN_SOURCE_ID" 2>/dev/null || true
  printf 'listen disarmed: %s\n' "$LISTEN_SOURCE_ID"
  return 0
}

case "${1:-check}" in
  check) action_check ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  listen-arm) action_listen_arm ;;
  listen-disarm) action_listen_disarm ;;
  -h|--help) usage ;;
  *) die_usage "unknown action: $1" ;;
esac
