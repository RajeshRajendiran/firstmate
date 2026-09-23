#!/usr/bin/env bash
# Behavior tests for bin/fm-telegram-check.sh, the standing Telegram check and
# the near-instant listen source.
#
# Surfaces exercised through their executable interfaces:
#
#   * arming/disarming state/telegram.check.sh with its trust binding;
#
#   * the `check` action, which runs the real fm-telegram.sh poll against a
#     scratch home whose .env and fake curl decide the outcome;
#
#   * the listen-arm/listen-disarm path, which registers and retires a
#     process-event source without contacting the real Telegram endpoint.
#
# No case ever contacts a real Telegram server.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-telegram-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-telegram-check)

TG_TOKEN="test-bot-token"
TG_CHAT="12345"

run_check() {
  local home=$1 out=$2 check=$3
  shift 3
  local status=0
  env -u FM_TELEGRAM_BOT_TOKEN -u FM_TELEGRAM_CAPTAIN_CHAT_ID \
    -u FM_TELEGRAM_CHECK_BUDGET \
    FM_CHECK_TIMEOUT=30 \
    "$@" FM_HOME="$home" PATH="$FAKEBIN:$PATH" \
    "$check" check >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "check exit"
}

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

write_env() {
  local home=$1
  printf '%s\n' \
    "FM_TELEGRAM_BOT_TOKEN=$TG_TOKEN" \
    "FM_TELEGRAM_CAPTAIN_CHAT_ID=$TG_CHAT" > "$home/.env"
}

enter_telegram() {
  local home=$1 generator=$2
  mkdir -p "$home/bin" "$FAKEBIN"
  [ -e "$home/bin/fm-wake-lib.sh" ] || ln -s "$ROOT/bin/fm-wake-lib.sh" "$home/bin/fm-wake-lib.sh"
  printf '%s\n' "$generator" > "$FAKEBIN/python3"
  chmod +x "$FAKEBIN/python3"
}

# Fake curl shared by the Telegram poll tests. It writes every request to
# $FM_TELEGRAM_CURL_LOG and returns the response held in
# $FM_TELEGRAM_FAKE_RESPONSE for getUpdates, or $FM_TELEGRAM_SEND_RESPONSE
# for sendMessage.
make_fake_curl() {
  local fakebin=$1
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
url=""
body=""
method="GET"
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -d) body="$2"; shift 2 ;;
    -K) url=$(sed -n 's/^url = "\(.*\)"$/\1/p'); shift 2 ;;
    -H|-sS|-m|--max-time|-w) shift 2 ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\t%s\t%s\n' "$method" "$url" "$body" >> "${FM_TELEGRAM_CURL_LOG:-/dev/null}"
case "$url" in
  *getUpdates*)
    printf '%s' "$FM_TELEGRAM_FAKE_RESPONSE"
    ;;
  *sendMessage*)
    printf '%s' "$FM_TELEGRAM_SEND_RESPONSE"
    printf '\n200'
    ;;
  *)
    printf '{"ok":false,"description":"unknown"}\n400'
    ;;
esac
SH
  chmod +x "$fakebin/curl"
}

FAKEBIN=$(fm_fakebin "$TMP_ROOT")

test_help_and_usage() {
  local out rc=0
  out=$("$CHECK" --help 2>&1) || rc=$?
  expect_code 0 "$rc" "--help must exit 0"
  assert_contains "$out" "check" "--help lists the check action"
  assert_contains "$out" "arm" "--help lists the arm action"
  assert_contains "$out" "disarm" "--help lists the disarm action"
  assert_contains "$out" "listen-arm" "--help lists the listen-arm action"
  assert_contains "$out" "listen-disarm" "--help lists the listen-disarm action"
  rc=0
  out=$("$CHECK" bogus 2>&1) || rc=$?
  expect_code 2 "$rc" "unknown action must exit 2"
  assert_contains "$out" "unknown action" "unknown action is refused loudly"
  pass "fm-telegram-check: help and usage plumbing"
}

test_arm_writes_and_binds_the_check_and_disarm_removes_it() {
  local home out
  home=$(make_home arm)
  write_env "$home"
  out=$(FM_HOME="$home" "$CHECK" arm 2>&1) || fail "arm must succeed: $out"
  assert_contains "$out" "armed: state/telegram.check.sh" "arm names the shim it wrote"
  assert_present "$home/state/telegram.check.sh" "arm writes the check shim"
  assert_present "$home/state/telegram.check-trust" "arm binds the shim for the watcher"
  assert_contains "$(cat "$home/state/telegram.check.sh")" "fm-telegram-check.sh check" "shim dispatches the check action"
  assert_contains "$(cat "$home/state/telegram.check.sh")" "FM_HOME=$home" "shim pins the absolute home"

  out=$(FM_HOME="$home" "$CHECK" arm 2>&1) || fail "re-arm must succeed: $out"
  assert_contains "$out" "armed" "re-arm stays armed"

  out=$(FM_HOME="$home" "$CHECK" disarm 2>&1) || fail "disarm must succeed: $out"
  assert_absent "$home/state/telegram.check.sh" "disarm removes the check shim"
  assert_absent "$home/state/telegram.check-trust" "disarm removes the trust binding"
  assert_absent "$home/state/.telegram-check" "disarm removes the report record"
  pass "fm-telegram-check: arm writes and binds, re-arm is idempotent, disarm removes"
}

test_arm_refuses_while_listen_is_registered() {
  local home out rc=0
  home=$(make_home arm-listen-block)
  write_env "$home"
  out=$(FM_HOME="$home" "$CHECK" listen-arm 2>&1) || fail "listen-arm must succeed: $out"
  assert_contains "$out" "listen armed" "listen-arm registers the source"
  assert_present "$home/state/procevent/telegram-listen.source" "listen-arm writes the source registration"

  out=$(FM_HOME="$home" "$CHECK" arm 2>&1) || rc=$?
  expect_code 1 "$rc" "arm must refuse while listen is registered"
  assert_contains "$out" "listen source is active" "arm names the active listen source"
  assert_absent "$home/state/telegram.check.sh" "arm refused by listen writes no shim"

  out=$(FM_HOME="$home" "$CHECK" listen-disarm 2>&1) || fail "listen-disarm must succeed: $out"
  assert_absent "$home/state/procevent/telegram-listen.source" "listen-disarm removes the registration"
  pass "fm-telegram-check: arm and listen are mutually exclusive"
}

test_listen_arm_refuses_while_standing_check_is_armed() {
  local home out rc=0
  home=$(make_home listen-arm-block)
  write_env "$home"
  out=$(FM_HOME="$home" "$CHECK" arm 2>&1) || fail "arm must succeed: $out"
  assert_present "$home/state/telegram.check.sh" "standing check is armed"

  out=$(FM_HOME="$home" "$CHECK" listen-arm 2>&1) || rc=$?
  expect_code 1 "$rc" "listen-arm must refuse while standing check is armed"
  assert_contains "$out" "standing check is armed" "listen-arm names the active standing check"
  assert_absent "$home/state/procevent/telegram-listen.source" "listen-arm refused by check writes no registration"

  out=$(FM_HOME="$home" "$CHECK" disarm 2>&1) || fail "disarm must succeed: $out"
  pass "fm-telegram-check: listen-arm and standing check are mutually exclusive"
}

test_successful_poll_with_new_message_emits_one_wake_line() {
  local home out wakeq
  home=$(make_home success)
  write_env "$home"
  make_fake_curl "$FAKEBIN"
  log="$home/curl.log"
  FM_TELEGRAM_FAKE_RESPONSE='{"ok":true,"result":['
  FM_TELEGRAM_FAKE_RESPONSE+='{"update_id":7,"message":{"chat":{"id":12345},"message_id":50,"date":1010,"from":{"id":12345,"username":"captain"},"text":"hello from phone"}}'
  FM_TELEGRAM_FAKE_RESPONSE+=']}'
  export FM_TELEGRAM_FAKE_RESPONSE FM_TELEGRAM_CURL_LOG="$log" FM_TELEGRAM_POLL_TIMEOUT=2 FM_TELEGRAM_SEND_RATE_LIMIT=0
  out="$home/out.txt"
  run_check "$home" "$out" "$CHECK"
  assert_contains "$(cat "$out")" "telegram: new message: woke for 7" "a successful poll that surfaces a message emits one wake line"
  [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] || fail "a successful new-message poll reports exactly one line: $(cat "$out")"
  assert_present "$home/state/.telegram-check" "a successful poll records its outcome"
  assert_contains "$(cat "$home/state/.telegram-check")" "fm-telegram-check-v1" "the record carries its schema"
  assert_contains "$(cat "$home/state/.telegram-check")" "reported=new message: woke for 7" "the record carries the reported new-message finding"
  wakeq="$home/state/.wake-queue"
  assert_contains "$(cat "$wakeq" 2>/dev/null)" "check: telegram 7" "the check-run poll still surfaces the message as a durable wake"
  assert_contains "$(cat "$home/state/telegram/7.json" 2>/dev/null)" "hello from phone" "the stashed record keeps the full text"
  pass "fm-telegram-check: a successful poll that surfaces a message emits one wake line"
}

test_check_runs_the_background_responder() {
  local home out
  home=$(make_home background-responder)
  write_env "$home"
  make_fake_curl "$FAKEBIN"
  FM_TELEGRAM_FAKE_RESPONSE='{"ok":true,"result":['
  FM_TELEGRAM_FAKE_RESPONSE+='{"update_id":8,"message":{"chat":{"id":12345},"message_id":51,"date":1011,"from":{"id":12345,"username":"captain"},"text":"ping"}}'
  FM_TELEGRAM_FAKE_RESPONSE+=']}'
  export FM_TELEGRAM_FAKE_RESPONSE FM_TELEGRAM_SEND_RESPONSE='{"ok":true,"result":{"message_id":1}}' \
    FM_TELEGRAM_CURL_LOG="$home/curl.log" FM_TELEGRAM_POLL_TIMEOUT=2 FM_TELEGRAM_SEND_RATE_LIMIT=0
  out="$home/out.txt"
  run_check "$home" "$out" "$CHECK"
  assert_present "$home/state/telegram/handled/8.json" "the standing check acknowledges the safe message in the background"
  assert_contains "$(cat "$home/state/telegram/responses/8.json")" '"status":"delivered"' "the background result is durable"
  assert_contains "$(cat "$home/curl.log")" "sendMessage" "the background responder sends without a main turn"
  pass "fm-telegram-check: polling invokes the acknowledgement-only background responder"
}

test_failure_is_reported_once_until_it_changes() {
  local home out
  home=$(make_home failure)
  write_env "$home"
  mkdir -p "$home/bin"
  [ -e "$home/bin/fm-wake-lib.sh" ] || ln -s "$ROOT/bin/fm-wake-lib.sh" "$home/bin/fm-wake-lib.sh"
  cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\t%s\n' "GET" "$*" "" >> "${FM_TELEGRAM_CURL_LOG:-/dev/null}"
exit 28
SH
  chmod +x "$FAKEBIN/curl"

  out="$home/out.txt"
  run_check "$home" "$out" "$CHECK"
  assert_contains "$(cat "$out")" "telegram: poll failed: curl error 28" "a failing poll reports its cause in one line"
  [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] || fail "a failing poll reports exactly one line: $(cat "$out")"

  out="$home/out2.txt"
  run_check "$home" "$out" "$CHECK"
  [ ! -s "$out" ] || fail "the same failure must not be reported again: $(cat "$out")"
  assert_contains "$(cat "$home/state/.telegram-check")" "reported=poll failed: curl error 28" "the record carries the reported finding"

  # A healthy poll clears the record, so the next failure is news again.
  make_fake_curl "$FAKEBIN"
  log="$home/curl2.log"
  FM_TELEGRAM_FAKE_RESPONSE='{"ok":true,"result":['
  FM_TELEGRAM_FAKE_RESPONSE+=']}'
  export FM_TELEGRAM_FAKE_RESPONSE FM_TELEGRAM_CURL_LOG="$log" FM_TELEGRAM_POLL_TIMEOUT=2 FM_TELEGRAM_SEND_RATE_LIMIT=0
  out="$home/out3.txt"
  run_check "$home" "$out" "$CHECK"
  [ ! -s "$out" ] || fail "a recovered poll must stay silent: $(cat "$out")"

  cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\t%s\n' "GET" "$*" "" >> "${FM_TELEGRAM_CURL_LOG:-/dev/null}"
exit 7
SH
  chmod +x "$FAKEBIN/curl"
  out="$home/out4.txt"
  run_check "$home" "$out" "$CHECK"
  assert_contains "$(cat "$out")" "telegram: poll failed: curl error 7" "a failure after a healthy poll is news again"
  pass "fm-telegram-check: a poll failure is reported once and re-reported after recovery"
}

test_unconfigured_home_is_reported_once() {
  local home out
  home=$(make_home unconfigured)
  out="$home/out.txt"
  run_check "$home" "$out" "$CHECK"
  assert_contains "$(cat "$out")" "telegram: missing required" "an unconfigured home reports the missing setup"
  assert_contains "$(cat "$out")" "FM_TELEGRAM_BOT_TOKEN" "the report names the missing token variable"

  out="$home/out2.txt"
  run_check "$home" "$out" "$CHECK"
  [ ! -s "$out" ] || fail "the unconfigured state must not repeat: $(cat "$out")"
  pass "fm-telegram-check: an unconfigured home is reported once, not every poll"
}

test_slow_poll_times_out_and_is_reported() {
  local home out
  home=$(make_home slow)
  write_env "$home"
  enter_telegram "$home" 'sleep 6'
  out="$home/out.txt"
  run_check "$home" "$out" "$CHECK" FM_TELEGRAM_CHECK_BUDGET=5
  assert_contains "$(cat "$out")" "telegram: poll did not finish within the 5s budget" "a poll past its budget is reported, not ignored"
  [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] || fail "a poll timeout reports exactly one line: $(cat "$out")"
  pass "fm-telegram-check: a slow poll times out into a one-line report"
}

test_check_stays_silent_when_listen_source_is_registered() {
  local home out
  home=$(make_home check-silent-with-listen)
  write_env "$home"
  out=$(FM_HOME="$home" "$CHECK" listen-arm 2>&1) || fail "listen-arm must succeed: $out"
  assert_contains "$out" "listen armed" "listen-arm registers the source"

  # The standing check must not run poll while the listen source is active,
  # because two long-polling consumers on one bot token would race.
  out="$home/out.txt"
  run_check "$home" "$out" "$CHECK"
  [ ! -s "$out" ] || fail "check must stay silent while listen is registered: $(cat "$out")"
  pass "fm-telegram-check: standing check stays silent while listen source is active"
}

test_missing_telegram_plane_is_reported() {
  local tmpbin home out check_bin
  tmpbin="$TMP_ROOT/plane/bin"
  home="$TMP_ROOT/plane/home"
  mkdir -p "$tmpbin" "$home/state"
  check_bin="$tmpbin/fm-telegram-check.sh"
  cp "$ROOT/bin/fm-telegram-check.sh" "$tmpbin/"
  for lib in fm-timeout-lib.sh fm-pr-lib.sh fm-line-cap-lib.sh fm-check-lib.sh; do
    [ -e "$tmpbin/$lib" ] || ln -s "$ROOT/bin/$lib" "$tmpbin/$lib"
  done
  out="$home/out.txt"
  run_check "$home" "$out" "$check_bin"
  assert_contains "$(cat "$out")" "telegram: fm-telegram.sh is missing next to this check" "a home lacking the Telegram plane reports it"
  pass "fm-telegram-check: a missing Telegram plane is reported, not assumed"
}

test_listen_arm_resolves_a_relative_home() {
  local home rel out
  home=$(make_home relative-listen)
  write_env "$home"
  rel="$(basename "$home")"
  out=$(cd "$TMP_ROOT" && env FM_HOME="$rel" "$CHECK" listen-arm 2>&1) || fail "listen-arm with a relative FM_HOME must succeed: $out"
  assert_contains "$out" "listen armed" "listen-arm succeeds with a relative home"
  pass "fm-telegram-check: listen-arm resolves a relative FM_HOME"
}

test_help_and_usage
test_arm_writes_and_binds_the_check_and_disarm_removes_it
test_arm_refuses_while_listen_is_registered
test_listen_arm_refuses_while_standing_check_is_armed
test_successful_poll_with_new_message_emits_one_wake_line
test_check_runs_the_background_responder
test_failure_is_reported_once_until_it_changes
test_unconfigured_home_is_reported_once
test_slow_poll_times_out_and_is_reported
test_check_stays_silent_when_listen_source_is_registered
test_missing_telegram_plane_is_reported
test_listen_arm_resolves_a_relative_home
