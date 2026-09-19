#!/usr/bin/env bash
# Behavior tests for bin/fm-telegram.sh.
#
# These tests exercise the Telegram plane through its executable public
# interface against a local fake Telegram endpoint. They never assert the
# internal source bytes of the scripts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TELEGRAM="$ROOT/bin/fm-telegram.sh"
TMP_ROOT=$(fm_test_tmproot fm-telegram)

# Common test configuration values.
TG_TOKEN="test-bot-token"
TG_CHAT="12345"

# Create a fresh home directory for a test, linking the wake library so the
# plane can append wakes into the temp home's state.
make_tg_home() {
  local home=$1
  mkdir -p "$home"
  mkdir -p "$home/bin"
  [ -e "$home/bin/fm-wake-lib.sh" ] || ln -s "$ROOT/bin/fm-wake-lib.sh" "$home/bin/fm-wake-lib.sh"
  printf '%s\n' "$home"
}

# Write a fake curl into a fakebin directory and prepend it to PATH.
# The fake writes every request to $FM_TELEGRAM_CURL_LOG and prints the
# response body held in $FM_TELEGRAM_FAKE_RESPONSE for getUpdates calls.
# For sendMessage calls it prints $FM_TELEGRAM_SEND_RESPONSE (default delivered).
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

test_missing_secret_fails_cleanly() {
  local out rc home
  home=$(make_tg_home "$TMP_ROOT/missing-home")
  env -u FM_TELEGRAM_BOT_TOKEN -u FM_TELEGRAM_CAPTAIN_CHAT_ID \
    FM_HOME="$home" "$TELEGRAM" status >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
  rc=$?
  expect_code 1 "$rc" "status without configuration must fail"
  out=$(cat "$TMP_ROOT/err")
  assert_contains "$out" "FM_TELEGRAM_BOT_TOKEN" "missing-config error names token variable"
  assert_contains "$out" "FM_TELEGRAM_CAPTAIN_CHAT_ID" "missing-config error names chat id variable"
  assert_not_contains "$out" "$TG_TOKEN" "missing-config error never leaks a secret"
  pass "fm-telegram: missing required configuration fails cleanly"
}

test_env_overrides_env_file() {
  local env_home out
  env_home=$(make_tg_home "$TMP_ROOT/envfile-home")
  cat > "$env_home/.env" <<EOF
FM_TELEGRAM_BOT_TOKEN=fromfile
FM_TELEGRAM_CAPTAIN_CHAT_ID=11111
EOF
  out=$(FM_HOME="$env_home" "$TELEGRAM" status 2>&1)
  assert_contains "$out" "captain chat id: 11111" "status uses .env when environment is unset"
  out=$(FM_TELEGRAM_CAPTAIN_CHAT_ID=22222 FM_HOME="$env_home" "$TELEGRAM" status 2>&1)
  assert_contains "$out" "captain chat id: 22222" "environment overrides .env for a direct invocation"
  pass "fm-telegram: environment values override the .env file"
}

test_status_without_network() {
  local out rc home
  home=$(make_tg_home "$TMP_ROOT/status-home")
  out=$(FM_TELEGRAM_BOT_TOKEN="$TG_TOKEN" FM_TELEGRAM_CAPTAIN_CHAT_ID="$TG_CHAT" \
    FM_HOME="$home" "$TELEGRAM" status 2>&1)
  rc=$?
  expect_code 0 "$rc" "status with configuration must succeed without network"
  assert_contains "$out" "telegram bot: configured" "status reports the bot is configured"
  assert_contains "$out" "captain chat id: $TG_CHAT" "status prints the configured chat id"
  assert_contains "$out" "last offset: 0" "status prints the initial offset"
  assert_contains "$out" "accepted: 0" "status prints the initial accepted count"
  assert_contains "$out" "dropped: 0" "status prints the initial dropped count"
  assert_not_contains "$out" "$TG_TOKEN" "status must never print the token"
  pass "fm-telegram: status succeeds without network and prints configuration"
}

test_poll_chat_filter_and_wake() {
  local fakebin out rc home log
  home=$(make_tg_home "$TMP_ROOT/poll-home")
  fakebin=$(fm_fakebin "$TMP_ROOT")
  make_fake_curl "$fakebin"
  log="$TMP_ROOT/poll.log"
  FM_TELEGRAM_FAKE_RESPONSE='{"ok":true,"result":['
  FM_TELEGRAM_FAKE_RESPONSE+='{"update_id":1,"message":{"chat":{"id":99999},"message_id":10,"date":1000,"from":{"id":99999,"username":"other"},"text":"from someone else"}},'
  FM_TELEGRAM_FAKE_RESPONSE+='{"update_id":2,"message":{"chat":{"id":12345},"message_id":11,"date":1001,"from":{"id":12345,"username":"captain"},"text":"captain says hi"}},'
  FM_TELEGRAM_FAKE_RESPONSE+='{"update_id":3,"message":{"chat":{"id":99999},"message_id":12,"date":1002,"from":{"id":99999,"username":"other"},"text":"more noise"}}'
  FM_TELEGRAM_FAKE_RESPONSE+=']}'
  export FM_TELEGRAM_FAKE_RESPONSE FM_TELEGRAM_CURL_LOG="$log"

  out=$(FM_TELEGRAM_BOT_TOKEN="$TG_TOKEN" FM_TELEGRAM_CAPTAIN_CHAT_ID="$TG_CHAT" \
    FM_HOME="$home" PATH="$fakebin:$PATH" FM_TELEGRAM_POLL_TIMEOUT=2 FM_TELEGRAM_SEND_RATE_LIMIT=0 \
    "$TELEGRAM" poll 2>&1)
  rc=$?
  expect_code 0 "$rc" "poll must succeed with filtered updates"
  assert_contains "$out" "woke for 2" "poll wakes only the captain's update"
  assert_contains "$(cat "$home/state/.wake-queue" 2>/dev/null)" "check: telegram 2 - captain says hi" \
    "wake queue carries the captain's message summary"
  assert_present "$home/state/telegram/2.json" "accepted message is stashed by update_id"
  assert_contains "$(cat "$home/state/telegram/2.json" 2>/dev/null)" "captain says hi" "stashed record keeps the full text"
  assert_equals "3" "$(cat "$home/state/.telegram-offset" 2>/dev/null)" "offset advances to the highest processed update_id"
  pass "fm-telegram: poll filters by chat id, stashes, wakes, and advances offset"
}

test_poll_counts_dropped_updates() {
  local fakebin out home log
  home=$(make_tg_home "$TMP_ROOT/dropped-home")
  fakebin=$(fm_fakebin "$TMP_ROOT")
  make_fake_curl "$fakebin"
  log="$TMP_ROOT/dropped.log"
  FM_TELEGRAM_FAKE_RESPONSE='{"ok":true,"result":['
  FM_TELEGRAM_FAKE_RESPONSE+='{"update_id":4,"message":{"chat":{"id":11111},"message_id":20,"date":1003,"from":{"id":11111,"username":"bot"},"text":"noise"}},'
  FM_TELEGRAM_FAKE_RESPONSE+='{"update_id":5,"message":{"chat":{"id":11111},"message_id":21,"date":1004,"from":{"id":11111,"username":"bot"},"text":"more noise"}}'
  FM_TELEGRAM_FAKE_RESPONSE+=']}'
  export FM_TELEGRAM_FAKE_RESPONSE FM_TELEGRAM_CURL_LOG="$log"

  out=$(FM_TELEGRAM_BOT_TOKEN="$TG_TOKEN" FM_TELEGRAM_CAPTAIN_CHAT_ID="$TG_CHAT" \
    FM_HOME="$home" PATH="$fakebin:$PATH" FM_TELEGRAM_POLL_TIMEOUT=2 FM_TELEGRAM_SEND_RATE_LIMIT=0 \
    "$TELEGRAM" poll 2>&1)
  assert_contains "$out" "no new messages" "poll reports nothing to wake when only non-captain messages arrive"
  assert_equals "5" "$(cat "$home/state/.telegram-offset" 2>/dev/null)" "offset advances past dropped updates"
  assert_contains "$(cat "$home/state/.telegram-stats" 2>/dev/null)" "dropped=2" "stats count the dropped updates"
  pass "fm-telegram: poll counts dropped updates and advances offset"
}

test_poll_dedupes_on_second_run() {
  local fakebin out rc count home log
  home=$(make_tg_home "$TMP_ROOT/dedup-home")
  fakebin=$(fm_fakebin "$TMP_ROOT")
  make_fake_curl "$fakebin"
  log="$TMP_ROOT/dedup.log"
  FM_TELEGRAM_FAKE_RESPONSE='{"ok":true,"result":['
  FM_TELEGRAM_FAKE_RESPONSE+='{"update_id":6,"message":{"chat":{"id":12345},"message_id":30,"date":1005,"from":{"id":12345,"username":"captain"},"text":"again"}}'
  FM_TELEGRAM_FAKE_RESPONSE+=']}'
  export FM_TELEGRAM_FAKE_RESPONSE FM_TELEGRAM_CURL_LOG="$log"

  out=$(FM_TELEGRAM_BOT_TOKEN="$TG_TOKEN" FM_TELEGRAM_CAPTAIN_CHAT_ID="$TG_CHAT" \
    FM_HOME="$home" PATH="$fakebin:$PATH" FM_TELEGRAM_POLL_TIMEOUT=2 FM_TELEGRAM_SEND_RATE_LIMIT=0 \
    "$TELEGRAM" poll 2>&1)
  rc=$?
  expect_code 0 "$rc" "first poll with a new captain update must succeed"
  assert_contains "$out" "woke for 6" "first poll wakes the new update"

  out=$(FM_TELEGRAM_BOT_TOKEN="$TG_TOKEN" FM_TELEGRAM_CAPTAIN_CHAT_ID="$TG_CHAT" \
    FM_HOME="$home" PATH="$fakebin:$PATH" FM_TELEGRAM_POLL_TIMEOUT=2 FM_TELEGRAM_SEND_RATE_LIMIT=0 \
    "$TELEGRAM" poll 2>&1)
  rc=$?
  expect_code 0 "$rc" "second poll must succeed"
  assert_not_contains "$out" "woke for 6" "re-polling the same update must not re-wake"
  assert_contains "$out" "no new messages" "second poll reports no new messages"
  count=$(grep -c "check: telegram 6" "$home/state/.wake-queue" 2>/dev/null || true)
  count=$(printf '%s' "$count" | tr -d '[:space:]')
  assert_equals "1" "$count" "exactly one wake row exists for the update"
  pass "fm-telegram: poll surfaces each accepted update exactly once"
}

test_send_splits_at_line_boundary() {
  local fakebin out chunk1 chunk2 len home line_a line_b
  home=$(make_tg_home "$TMP_ROOT/send-split-home")
  fakebin=$(fm_fakebin "$TMP_ROOT")
  make_fake_curl "$fakebin"
  export FM_TELEGRAM_CURL_LOG="$TMP_ROOT/send-split.log" FM_TELEGRAM_SEND_RATE_LIMIT=0 FM_TELEGRAM_SEND_RESPONSE='{"ok":true,"result":{"message_id":1}}'

  line_a=$(python3 -c 'print("a" * 2500)')
  line_b=$(python3 -c 'print("b" * 2500)')
  out=$(printf '%s\n%s\n' "$line_a" "$line_b" | FM_TELEGRAM_BOT_TOKEN="$TG_TOKEN" FM_TELEGRAM_CAPTAIN_CHAT_ID="$TG_CHAT" \
    FM_HOME="$home" PATH="$fakebin:$PATH" FM_TELEGRAM_SEND_TIMEOUT=2 FM_TELEGRAM_SEND_RATE_LIMIT=0 \
    "$TELEGRAM" send - 2>&1)
  rc=$?
  expect_code 0 "$rc" "send with split must succeed"
  assert_contains "$out" "delivered: 1/2" "first chunk reports delivered"
  assert_contains "$out" "delivered: 2/2" "second chunk reports delivered"

  # The log records method, URL, body for each request.
  assert_equals "2" "$(wc -l < "$TMP_ROOT/send-split.log" | tr -d '[:space:]')" "send posts two chunks"
  chunk1=$(sed -n '1p' "$TMP_ROOT/send-split.log" | cut -f3)
  chunk2=$(sed -n '2p' "$TMP_ROOT/send-split.log" | cut -f3)
  assert_contains "$chunk1" "chat_id" "first chunk targets the captain chat"
  assert_contains "$chunk2" "chat_id" "second chunk targets the captain chat"
  len=$(python3 -c 'import sys, json; print(len(json.loads(sys.argv[1])["text"]))' "$chunk1")
  assert_equals "2500" "$len" "first chunk length is one line"
  len=$(python3 -c 'import sys, json; print(len(json.loads(sys.argv[1])["text"]))' "$chunk2")
  assert_equals "2500" "$len" "second chunk length is the other line"
  pass "fm-telegram: send splits long text at line boundaries"
}

test_send_reports_delivered() {
  local fakebin out home
  home=$(make_tg_home "$TMP_ROOT/send-delivered-home")
  fakebin=$(fm_fakebin "$TMP_ROOT")
  make_fake_curl "$fakebin"
  export FM_TELEGRAM_CURL_LOG="$TMP_ROOT/send-delivered.log" FM_TELEGRAM_SEND_RESPONSE='{"ok":true,"result":{"message_id":1}}'

  out=$(FM_TELEGRAM_BOT_TOKEN="$TG_TOKEN" FM_TELEGRAM_CAPTAIN_CHAT_ID="$TG_CHAT" \
    FM_HOME="$home" PATH="$fakebin:$PATH" FM_TELEGRAM_SEND_TIMEOUT=2 FM_TELEGRAM_SEND_RATE_LIMIT=0 \
    "$TELEGRAM" send "hello" 2>&1)
  rc=$?
  expect_code 0 "$rc" "send must succeed on delivered response"
  assert_contains "$out" "delivered: 1/1" "send reports delivered for one chunk"
  pass "fm-telegram: send reports delivered"
}

test_send_reports_not_delivered() {
  local fakebin out home
  home=$(make_tg_home "$TMP_ROOT/send-nd-home")
  fakebin=$(fm_fakebin "$TMP_ROOT")
  make_fake_curl "$fakebin"
  export FM_TELEGRAM_SEND_RESPONSE='{"ok":false,"description":"Bad Request: chat not found"}'
  export FM_TELEGRAM_CURL_LOG="$TMP_ROOT/send-nd.log"

  out=$(FM_TELEGRAM_BOT_TOKEN="$TG_TOKEN" FM_TELEGRAM_CAPTAIN_CHAT_ID="$TG_CHAT" \
    FM_HOME="$home" PATH="$fakebin:$PATH" FM_TELEGRAM_SEND_TIMEOUT=2 FM_TELEGRAM_SEND_RATE_LIMIT=0 \
    "$TELEGRAM" send "hello" 2>&1)
  rc=$?
  expect_code 0 "$rc" "send must exit 0 when the API reports not-delivered"
  assert_contains "$out" "not-delivered: 1/1" "send reports not-delivered"
  assert_contains "$out" "telegram error" "not-delivered reason names the telegram error"
  pass "fm-telegram: send reports not-delivered"
}

test_send_reports_ambiguous() {
  local fakebin out home
  home=$(make_tg_home "$TMP_ROOT/send-amb-home")
  fakebin=$(fm_fakebin "$TMP_ROOT")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
log="${FM_TELEGRAM_CURL_LOG:-/dev/null}"
printf '%s\t%s\t%s\n' "POST" "$*" "" >> "$log"
exit 28
SH
  chmod +x "$fakebin/curl"
  export FM_TELEGRAM_CURL_LOG="$TMP_ROOT/send-amb.log"

  out=$(FM_TELEGRAM_BOT_TOKEN="$TG_TOKEN" FM_TELEGRAM_CAPTAIN_CHAT_ID="$TG_CHAT" \
    FM_HOME="$home" PATH="$fakebin:$PATH" FM_TELEGRAM_SEND_TIMEOUT=2 FM_TELEGRAM_SEND_RATE_LIMIT=0 \
    "$TELEGRAM" send "hello" 2>&1)
  rc=$?
  expect_code 0 "$rc" "send must exit 0 when curl times out"
  assert_contains "$out" "ambiguous: 1/1" "send reports ambiguous on curl failure"
  pass "fm-telegram: send reports ambiguous on timeout"
}

test_help_plumbing() {
  local out rc home
  home=$(make_tg_home "$TMP_ROOT/help-home")
  out=$(FM_TELEGRAM_BOT_TOKEN="$TG_TOKEN" FM_TELEGRAM_CAPTAIN_CHAT_ID="$TG_CHAT" \
    FM_HOME="$home" "$TELEGRAM" --help 2>&1)
  rc=$?
  expect_code 0 "$rc" "--help must exit 0"
  assert_contains "$out" "poll" "--help lists the poll subcommand"
  assert_contains "$out" "send" "--help lists the send subcommand"
  assert_contains "$out" "status" "--help lists the status subcommand"
  pass "fm-telegram: --help prints usage for every subcommand"
}

test_unknown_subcommand_prints_usage() {
  local out rc home
  home=$(make_tg_home "$TMP_ROOT/unknown-home")
  out=$(FM_TELEGRAM_BOT_TOKEN="$TG_TOKEN" FM_TELEGRAM_CAPTAIN_CHAT_ID="$TG_CHAT" \
    FM_HOME="$home" "$TELEGRAM" bogus 2>&1)
  rc=$?
  expect_code 1 "$rc" "unknown subcommand must exit 1"
  assert_contains "$out" "poll" "unknown subcommand prints usage"
  assert_contains "$out" "status" "unknown subcommand prints usage"
  pass "fm-telegram: unknown subcommand prints usage and exits non-zero"
}

test_no_secret_leaked_to_status() {
  local out home
  home=$(make_tg_home "$TMP_ROOT/secret-home")
  out=$(FM_TELEGRAM_BOT_TOKEN="$TG_TOKEN" FM_TELEGRAM_CAPTAIN_CHAT_ID="$TG_CHAT" \
    FM_HOME="$home" "$TELEGRAM" status 2>&1)
  assert_not_contains "$out" "$TG_TOKEN" "status must never print the bot token"
  pass "fm-telegram: status never prints the bot token"
}

test_missing_secret_fails_cleanly
test_env_overrides_env_file
test_status_without_network
test_poll_chat_filter_and_wake
test_poll_counts_dropped_updates
test_poll_dedupes_on_second_run
test_send_splits_at_line_boundary
test_send_reports_delivered
test_send_reports_not_delivered
test_send_reports_ambiguous
test_help_plumbing
test_unknown_subcommand_prints_usage
test_no_secret_leaked_to_status
