#!/usr/bin/env bash
# Behavior tests for bin/fm-procevent-telegram.sh, driven through its CLI.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ADAPTER="$ROOT/bin/fm-procevent-telegram.sh"
TMP_ROOT=$(fm_test_tmproot fm-procevent-telegram)

test_silent_only_for_clean_results() {
  local rc
  : > "$TMP_ROOT/empty"
  "$ADAPTER" silent "$TMP_ROOT/empty"; rc=$?
  expect_code 0 "$rc" "empty result is silent"
  printf 'fm-telegram: poll failed (1/5), retrying in 5s\n' > "$TMP_ROOT/retry"
  "$ADAPTER" silent "$TMP_ROOT/retry"; rc=$?
  expect_code 0 "$rc" "transient retry output is silent"
  printf 'fm-telegram: poll failed (4/5)\nfm-telegram: listen exiting after 5 consecutive poll failures\n' > "$TMP_ROOT/dead"
  "$ADAPTER" silent "$TMP_ROOT/dead"; rc=$?
  expect_code 1 "$rc" "listener death is announced"
  pass "fm-procevent-telegram: silent announces only listener death"
}

test_terminal_and_autohandle() {
  local rc
  "$ADAPTER" terminal "$TMP_ROOT/empty"; rc=$?
  expect_code 1 "$rc" "listener result is never terminal"
  "$ADAPTER" autohandle src 1 "$TMP_ROOT/empty"; rc=$?
  expect_code 0 "$rc" "autohandle is a no-op"
  pass "fm-procevent-telegram: terminal and autohandle"
}

test_classify() {
  local out rc
  : > "$TMP_ROOT/c-empty"
  out=$("$ADAPTER" classify "$TMP_ROOT/c-empty")
  assert_equals "listening" "$out" "empty result classifies as listening"
  printf 'oops\n' > "$TMP_ROOT/c-err"
  out=$("$ADAPTER" classify "$TMP_ROOT/c-err")
  assert_equals "error" "$out" "non-empty result classifies as error"
  "$ADAPTER" classify "$TMP_ROOT/missing" >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "missing result file is a usage error"
  pass "fm-procevent-telegram: classify"
}

test_silent_only_for_clean_results
test_terminal_and_autohandle
test_classify
