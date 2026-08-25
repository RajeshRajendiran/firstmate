#!/usr/bin/env bash
# End-to-end reproduction of the stale-run incident and its safety counterparts,
# rendered through the captain-facing surfaces (fm-crew-state.sh, fm-fleet-view.sh
# and the watcher's own escalate/absorb predicate).
#   $1 = bin dir to exercise (holds the fm-crew-state.sh under test)
#   $2 = scenario: incident | genuine-failure | pending-relaunch
set -eu
BIN=$1; SCENARIO=$2
SANDBOX=$(mktemp -d /tmp/fm-incident.XXXXXX)
export GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.invalid
export GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.invalid

HOME_DIR=$SANDBOX/fmhome; WT=$SANDBOX/wt
mkdir -p "$HOME_DIR"/{state,data,config,projects} "$WT"
git -C "$WT" init -q
git -C "$WT" commit -q --allow-empty -m init
git -C "$WT" checkout -q -b fm/feat-relaunch
git -C "$WT" commit -q --allow-empty -m "crew work"
LOCAL_SHORT=$(git -C "$WT" rev-parse --short=7 HEAD)
git -C "$WT" checkout -q --orphan tmp-diverged
git -C "$WT" commit -q --allow-empty -m "rebased pipeline head"
DIVERGED_SHORT=$(git -C "$WT" rev-parse --short=7 HEAD)
git -C "$WT" checkout -q fm/feat-relaunch

FB=$SANDBOX/fakebin; mkdir -p "$FB"
cat > "$FB/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  axi)  shift; case "${1:-}" in status) printf '%s\n' "${FM_FAKE_AXI_STATUS:-}" ;; logs) printf '' ;; esac ;;
  runs) printf '%s\n' "${FM_FAKE_RUNS_LIST:-}" ;;
esac
exit 0
SH
cat > "$FB/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows)    sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta ;;
  display-message) printf '%%1\n' ;;
  capture-pane)    printf 'work in progress\nesc to interrupt\n' ;;
esac
exit 0
SH
chmod +x "$FB/no-mistakes" "$FB/tmux"
cat > "$HOME_DIR/state/relaunch.meta" <<EOF
window=fm:fm-relaunch
worktree=$WT
kind=ship
harness=claude
EOF
export FM_HOME="$HOME_DIR" PATH="$FB:$PATH"
GEN=$("$BIN/fm-busy-event.sh" arm "$HOME_DIR/state" relaunch)
"$BIN/fm-busy-event.sh" apply "$HOME_DIR/state" relaunch busy --gen "$GEN" \
  --source claude-hook --event user-prompt-submit >/dev/null

# `axi status` answers with some OTHER crew's run, so this branch is resolved
# through the runs list - exactly the incident's code path.
export FM_FAKE_AXI_STATUS="run:
  id: \"01OTHER\"
  branch: fm/other-crew
  status: running
  head: \"0000000\"
  pr: \"\"
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,running,0,0"

case $SCENARIO in
  incident)
    NOTE="newest run is IN FLIGHT with a pipeline-rebased head; an older FAILED run still matches the worktree tip"
    export FM_FAKE_RUNS_LIST="  running    fm/other-crew aaaaaaa  2026-08-25 22:10
  running    fm/feat-relaunch ${DIVERGED_SHORT}  2026-08-25 15:08
  failed     fm/feat-relaunch ${LOCAL_SHORT}  2026-08-22 16:18" ;;
  genuine-failure)
    NOTE="SAFETY COUNTERPART: the branch's newest run genuinely failed on this exact code"
    export FM_FAKE_RUNS_LIST="  running    fm/other-crew aaaaaaa  2026-08-25 22:10
  failed     fm/feat-relaunch ${LOCAL_SHORT}  2026-08-25 21:00
  completed  fm/feat-relaunch ${LOCAL_SHORT}  2026-08-24 09:00" ;;
  pending-relaunch)
    NOTE="a freshly relaunched run is PENDING on this code, and an earlier run left a 'checks green' line in the status log"
    printf 'done: PR https://github.com/o/r/pull/9 checks green\n' > "$HOME_DIR/state/relaunch.status"
    export FM_FAKE_RUNS_LIST="  running    fm/other-crew aaaaaaa  2026-08-25 22:10
  pending    fm/feat-relaunch ${LOCAL_SHORT}  2026-08-25 22:09
  completed  fm/feat-relaunch ${LOCAL_SHORT}  2026-08-24 09:00" ;;
esac

echo "--- scenario: $SCENARIO"
echo "    $NOTE"
echo
echo "\$ no-mistakes runs --limit 40"
printf '%s\n' "$FM_FAKE_RUNS_LIST" | sed 's/^/    /'
echo "    (worktree tip = ${LOCAL_SHORT}; rebased in-flight head = ${DIVERGED_SHORT})"
[ -s "$HOME_DIR/state/relaunch.status" ] && {
  echo
  echo "\$ tail -1 state/relaunch.status"
  tail -1 "$HOME_DIR/state/relaunch.status" | sed 's/^/    /'
}
echo
echo "\$ fm-crew-state.sh relaunch"
"$BIN/fm-crew-state.sh" relaunch | sed 's/^/    /'
echo
echo "\$ fm-fleet-view.sh   (captain's board, 'Under Way' row)"
"$BIN/fm-fleet-view.sh" 2>&1 | sed -n '/^## Under Way/,/^$/p' | sed 's/^/    /'
echo "\$ watcher predicate: crew_is_provably_working relaunch"
if ( . "$BIN/fm-classify-lib.sh"; crew_is_provably_working relaunch ); then
  echo "    -> true   (absorbed as working; NO failure escalation to the captain)"
else
  echo "    -> false  (surfaced to the captain as not-working)"
fi
echo
rm -rf "$SANDBOX"
