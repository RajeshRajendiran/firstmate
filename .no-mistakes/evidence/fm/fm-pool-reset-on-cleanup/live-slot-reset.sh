#!/usr/bin/env bash
# Live drive: real treehouse v3 pool + real git + real bin/fm-teardown.sh in a
# marked lab FM_HOME. Only GitHub (gh/gh-axi), no-mistakes and tmux are stubbed,
# because a real merged PR cannot exist here.
# Usage: live-slot-reset.sh <bin-dir-of-firstmate-checkout> <scenario: clean|dirty|other-task>
set -u
BIN=$1; SCEN=${2:-clean}
GATE_WT=/home/agent/.no-mistakes/worktrees/37339719b87e/01M4D450FTE0YHQXSSAZNW1W5B
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
"$GATE_WT/bin/fm-lab-home.sh" create "$LAB/home" >/dev/null
export FM_HOME="$LAB/home" TREEHOUSE_ROOT="$LAB/pool"
G="git -c user.email=t@t -c user.name=t"
say() { printf '\n### %s\n' "$*"; }

git init -q --bare "$LAB/origin.git"; git -C "$LAB/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$LAB/origin.git" "$LAB/seed" 2>/dev/null
echo base > "$LAB/seed/README"; $G -C "$LAB/seed" add README; $G -C "$LAB/seed" commit -qm baseline; git -C "$LAB/seed" push -q origin main
git clone -q "$LAB/origin.git" "$LAB/project"; git -C "$LAB/project" remote set-head origin main
cd "$LAB/project"

say "acquire slot with real treehouse"
SLOT=$(treehouse get --lease 2>/dev/null); echo "slot=$SLOT"
$G -C "$SLOT" switch -qc fm/task-x1
echo hello > "$SLOT/feature.txt"; $G -C "$SLOT" add feature.txt; $G -C "$SLOT" commit -qm "add feature"
$G -C "$SLOT" commit -q --allow-empty -m "review fixup"
git -C "$SLOT" push -q origin fm/task-x1
PR_HEAD=$(git -C "$SLOT" rev-parse HEAD)
say "squash-merge on origin (new single commit on main), delete PR branch"
$G -C "$LAB/seed" pull -q; echo hello > "$LAB/seed/feature.txt"; $G -C "$LAB/seed" add feature.txt
$G -C "$LAB/seed" commit -qm "add feature (#7)"; git -C "$LAB/seed" push -q origin main
git -C "$LAB/seed" push -q origin :fm/task-x1
git -C "$LAB/project" fetch -q --prune origin
git -C "$SLOT" checkout -q --detach   # crewmate leaves branch behind, as the pool keeps detached HEADs
git -C "$LAB/project" branch -D fm/task-x1 -q 2>/dev/null || true

case $SCEN in
  dirty) echo scratch > "$SLOT/notes.tmp" ;;
esac

fakebin="$LAB/fakebin"; mkdir -p "$fakebin"
cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 1 (showing first 1)" "pull_requests[1]{number,state}:" "  7,merged" ;;
  "pr view") printf '%s\n' "pull_request:" "  number: 7" "  state: merged" '  merged: "2026-10-08T00:00:00Z"' ;;
esac
exit 0
SH
cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
case " \$* " in
  *"state,headRefOid,url"*) printf '%s\t%s\t%s\n' MERGED $PR_HEAD https://github.com/example/repo/pull/7 ;;
  *headRefOid*) echo $PR_HEAD ;;
  *) exit 1 ;;
esac
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/tmux"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/no-mistakes"
chmod +x "$fakebin"/*
touch "$FM_HOME/state/.last-watcher-beat"
w() { printf '%s\n' "window=firstmate:fm-$1" "endpoint_task_id=$1" "worktree=$SLOT" "project=$LAB/project" kind=ship mode=no-mistakes "spawn_gen=lab-$1" "pr=https://github.com/example/repo/pull/7" "pr_head=$PR_HEAD" > "$FM_HOME/state/$1.meta"; }
w task-x1
[ "$SCEN" = other-task ] && w task-y2

say "slot before teardown"
echo "HEAD=$(git -C "$SLOT" rev-parse --short HEAD) origin/main=$(git -C "$SLOT" rev-parse --short origin/main)"
git -C "$SLOT" merge-base --is-ancestor HEAD origin/main && echo "HEAD is ancestor of main" || echo "HEAD is NOT an ancestor of main (pre-squash)"

say "run fm-teardown.sh task-x1 (bin=$BIN)"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  PATH="$fakebin:$PATH" "$BIN/fm-teardown.sh" task-x1 2>&1 | grep -Ei "slot|teardown:|REFUSED|error" | head -20
echo "teardown exit=${PIPESTATUS[0]}"

say "slot after teardown"
echo "HEAD=$(git -C "$SLOT" rev-parse --short HEAD) branch=$(git -C "$SLOT" rev-parse --abbrev-ref HEAD) status=[$(git -C "$SLOT" status --porcelain | tr '\n' ' ')]"
git -C "$SLOT" merge-base --is-ancestor HEAD origin/main && echo "HEAD is ancestor of main" || echo "HEAD is NOT an ancestor of main"
treehouse status 2>&1 | tail -n +1

say "next worker: treehouse get --lease"
NEXT=$(treehouse get --lease 2>"$LAB/get.err"); cat "$LAB/get.err" | grep -v '^$' | head -5
echo "next=$NEXT"; [ "$NEXT" = "$SLOT" ] && echo "RESULT: same slot reused" || echo "RESULT: different slot (slot was NOT reused)"
ls "$LAB/pool"/*/ 2>/dev/null | head
