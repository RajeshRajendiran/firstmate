#!/usr/bin/env bash
# Checks the header's stated residual limitation: with no attributable run and an
# idle pane, an EARLIER run's terminal `failed:` status-log line still reports failed.
set -eu
BIN=$1
S=$(mktemp -d /tmp/fm-lim.XXXXXX)
export GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.invalid
export GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.invalid
H=$S/fmhome WT=$S/wt
mkdir -p "$H"/{state,data,config,projects} "$WT"
git -C "$WT" init -q; git -C "$WT" commit -q --allow-empty -m init
git -C "$WT" checkout -q -b fm/feat-relaunch; git -C "$WT" commit -q --allow-empty -m work
L=$(git -C "$WT" rev-parse --short=7 HEAD)
git -C "$WT" checkout -q --orphan d; git -C "$WT" commit -q --allow-empty -m rebased
D=$(git -C "$WT" rev-parse --short=7 HEAD); git -C "$WT" checkout -q fm/feat-relaunch
FB=$S/fakebin; mkdir -p "$FB"
cat > "$FB/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  axi) shift; case "${1:-}" in status) printf '%s\n' "${FM_FAKE_AXI_STATUS:-}";; logs) printf '';; esac;;
  runs) printf '%s\n' "${FM_FAKE_RUNS_LIST:-}";;
esac
exit 0
SH
cat > "$FB/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta ;;
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
exit 0
SH
chmod +x "$FB/no-mistakes" "$FB/tmux"
printf 'window=fm:fm-relaunch\nworktree=%s\nkind=ship\nharness=claude\n' "$WT" > "$H/state/relaunch.meta"
printf 'failed: gate review found blockers\n' > "$H/state/relaunch.status"
export FM_HOME=$H PATH="$FB:$PATH"
G=$("$BIN/fm-busy-event.sh" arm "$H/state" relaunch)
"$BIN/fm-busy-event.sh" apply "$H/state" relaunch idle --gen "$G" --source claude-hook --event stop >/dev/null
export FM_FAKE_AXI_STATUS="run:
  id: \"01OTHER\"
  branch: fm/other-crew
  status: running
  head: \"0000000\"
  pr: \"\"
  findings: none
  steps[1]{step,status,findings,duration_ms}:
    review,running,0,0"
export FM_FAKE_RUNS_LIST="  running    fm/feat-relaunch ${D}  2026-08-25 15:08
  failed     fm/feat-relaunch ${L}  2026-08-22 16:18"
echo "idle pane + earlier 'failed:' status-log line + unattributable newest run:"
"$BIN/fm-crew-state.sh" relaunch | sed 's/^/    /'
rm -rf "$S"
