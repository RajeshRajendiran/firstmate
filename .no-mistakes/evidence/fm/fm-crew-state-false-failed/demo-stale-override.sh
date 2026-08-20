#!/usr/bin/env bash
# End-to-end demonstration of the fm-crew-state.sh false-fail fix.
# Drives the REAL bin/fm-crew-state.sh (and the base-commit version) through a
# minimal hermetic fake `no-mistakes` / `tmux` / `herdr` toolbin - the same
# technique the test suite uses - so no real no-mistakes install is required.
# Prints the helper's actual verdict for the buggy (base) and fixed (target)
# versions side by side for the stale-record-override scenario.
set -u

PROJ="$PWD"
while [ "$PROJ" != "/" ] && [ ! -x "$PROJ/bin/fm-crew-state.sh" ]; do
  PROJ="$(dirname "$PROJ")"
done
[ -x "$PROJ/bin/fm-crew-state.sh" ] || { echo "no project root found" >&2; exit 2; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- minimal hermetic fakes (mirror tests/fm-crew-state.test.sh) -------------
make_fakebin() {  # <dir>
  local fb="$1/fakebin"; mkdir -p "$fb"
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  axi) shift
       case "${1:-}" in
         status) shift
                 if [ "${1:-}" = --run ]; then printf '%s\n' "${FM_FAKE_AXI_STATUS_RUN:-}"
                 else printf '%s\n' "${FM_FAKE_AXI_STATUS:-}"; fi ;;
         logs)   printf '%s\n' "${FM_FAKE_CI_LOGS:-}" ;;
       esac ;;
  runs) printf '%s\n' "${FM_FAKE_RUNS_LIST:-}" ;;
esac
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane)    printf 'all quiet\n> \n' ;;
esac
exit 0
SH
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  status) [ "${2:-}" = --json ] && { printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'; exit 0; } ;;
  server) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux" "$fb/herdr"
  printf '%s\n' "$fb"
}

run_failed() {  # <branch>  -> TOON `axi status` for a terminal FAILED run
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
outcome: failed
EOF
}

write_meta() {  # <file> <lines...>
  local f=$1; shift
  : > "$f"
  for ln in "$@"; do printf '%s\n' "$ln" >> "$f"; done
}

run_scenario() {  # <bin> <label>
  local bin=$1 label=$2 d short fb
  d="$WORK/$label"; mkdir -p "$d/state" "$d/wt"
  git -C "$d/wt" init -q
  git -C "$d/wt" commit -q --allow-empty -m init
  git -C "$d/wt" checkout -q -b fm/feat-override
  FM_FAKE_RUN_HEAD=$(git -C "$d/wt" rev-parse HEAD); export FM_FAKE_RUN_HEAD
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  fb=$(make_fakebin "$d")
  write_meta "$d/state/feat-override.meta" \
    "window=fm:fm-feat-override" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-override)"; export FM_FAKE_AXI_STATUS
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/feat-override ${short}  2026-08-01 09:30
  failed     fm/feat-override ${short}  2026-08-01 09:00
EOF
)"; export FM_FAKE_RUNS_LIST
  echo "===== $label ====="
  PATH="$fb:$PATH" FM_STATE_OVERRIDE="$d/state" "$bin" feat-override
  echo
}

# Base version placed INSIDE bin/ so its `source "$SCRIPT_DIR/..."` libs resolve.
BASE_BIN="$PROJ/bin/.demo-base-fm-crew-state.sh"
git -C "$PROJ" show 87681a40777bb061ef923ef98b494cd7ef6054b6:bin/fm-crew-state.sh > "$BASE_BIN"
chmod +x "$BASE_BIN"

run_scenario "$BASE_BIN"                "BEFORE FIX (base commit 87681a4)"
run_scenario "$PROJ/bin/fm-crew-state.sh" "AFTER FIX (target commit ca42337)"

rm -f "$BASE_BIN"