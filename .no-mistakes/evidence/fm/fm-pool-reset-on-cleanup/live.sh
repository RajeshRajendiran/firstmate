#!/usr/bin/env bash
# usage: live.sh <scripts-root> <label> <scenario: squash|dirty|unlanded|force>
set -u
ROOT=$1; LABEL=$2; SCEN=${3:-squash}
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid
L=$(mktemp -d /tmp/nmlive/lab.XXXX); L=$(cd -P "$L" && pwd -P)
say(){ printf '\n$ %s\n' "$*"; }
"$ROOT/bin/fm-lab-home.sh" create "$L/home" >/dev/null || { echo lab-home-failed; exit 1; }
mkdir -p "$L/fakebin"
touch "$L/home/state/.last-watcher-beat"
for f in tmux no-mistakes; do printf '#!/usr/bin/env bash\nexit 0\n' > "$L/fakebin/$f"; done
git init -q --bare "$L/origin.git"; git -C "$L/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$L/origin.git" "$L/seed" 2>/dev/null
echo base > "$L/seed/README"; git -C "$L/seed" add README; git -C "$L/seed" commit -qm baseline; git -C "$L/seed" push -q origin main
git clone -q "$L/origin.git" "$L/project"; git -C "$L/project" remote set-head origin main
export TREEHOUSE_ROOT="$L/pool"
echo "== [$LABEL/$SCEN] real treehouse $(treehouse --version)"
say "treehouse get --lease   (task-x1 acquires a slot)"
SLOT=$(cd "$L/project" && treehouse get --lease 2>/dev/null); echo "$SLOT"
git -C "$SLOT" switch -q -c fm/task-x1
echo feature > "$SLOT/feature.txt"; git -C "$SLOT" add feature.txt; git -C "$SLOT" commit -qm "add feature (pre-squash)"
echo more >> "$SLOT/feature.txt"; git -C "$SLOT" commit -qam "follow-up (pre-squash)"
HEADC=$(git -C "$SLOT" rev-parse HEAD)
[ "$SCEN" = unlanded ] || git -C "$SLOT" push -q origin fm/task-x1
if [ "$SCEN" != unlanded ]; then
  git clone -q "$L/origin.git" "$L/land"; git -C "$L/land" checkout -q main
  git -C "$L/land" merge -q --squash origin/fm/task-x1 >/dev/null; git -C "$L/land" commit -qm "Squash-merge PR #7"
  git -C "$L/land" push -q origin main; rm -rf "$L/land"
  git -C "$L/project" fetch -q origin
  echo "origin/main is now squash commit $(git -C "$L/project" rev-parse --short origin/main); pre-squash head $(git -C "$SLOT" rev-parse --short HEAD)"
  say "git merge-base --is-ancestor <slot HEAD> origin/main  (treehouse reuse test)"
  git -C "$SLOT" merge-base --is-ancestor HEAD origin/main && echo ancestor || echo "NOT an ancestor -> treehouse will not reuse as-is"
fi
cat > "$L/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 1 (showing first 1)" "pull_requests[1]{number,state}:" "  7,merged" ;;
  "pr view") printf '%s\n' "pull_request:" "  number: 7" "  state: merged" '  merged: "2026-10-08T00:00:00Z"' ;;
esac
exit 0
SH
cat > "$L/fakebin/gh" <<SH
#!/usr/bin/env bash
case " \$* " in
  *"state,headRefOid,url"*) printf '%s\t%s\t%s\n' MERGED $HEADC https://github.com/example/repo/pull/7; exit 0;;
  *headRefOid*) echo $HEADC; exit 0;;
esac
exit 1
SH
if [ "$SCEN" = unlanded ]; then printf '#!/usr/bin/env bash\necho "error: pull request not found" >&2; exit 1\n' > "$L/fakebin/gh"; printf '#!/usr/bin/env bash\ncase "${1:-} ${2:-}" in "pr list") printf "%%s\\n" "count: 0 (showing first 0)" "pull_requests[]: []";; *) exit 1;; esac\n' > "$L/fakebin/gh-axi"; fi
chmod +x "$L/fakebin"/*
printf '%s\n' "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" "worktree=$SLOT" "project=$L/project" \
  kind=ship mode=no-mistakes spawn_gen=lab-task-x1 $( [ "$SCEN" = unlanded ] || echo "pr=https://github.com/example/repo/pull/7 pr_head=$HEADC") > "$L/home/state/task-x1.meta"
[ "$SCEN" = dirty ] && echo "uncommitted" > "$SLOT/scratch.txt"
FORCE=; [ "$SCEN" = force ] && FORCE=--force
say "fm-teardown.sh task-x1 $FORCE   ($LABEL scripts)"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$L/home" \
  PATH="$L/fakebin:$PATH" "$ROOT/bin/fm-teardown.sh" task-x1 $FORCE 2>&1 | grep -E "teardown:|REFUSED|error|torn|Torn" | grep -v "^$"
echo "teardown exit=${PIPESTATUS[0]}"
say "slot after teardown"
echo "HEAD=$(git -C "$SLOT" rev-parse --short HEAD) ($(git -C "$SLOT" rev-parse --abbrev-ref HEAD)) origin/main=$(git -C "$SLOT" rev-parse --short origin/main) dirty=[$(git -C "$SLOT" status --porcelain | tr '\n' ' ')]"
say "treehouse status"; (cd "$L/project" && treehouse status 2>&1)
say "treehouse get --lease   (next worker)"
NEXT=$(cd "$L/project" && treehouse get --lease 2>&1 >"$L/next"); NEXTP=$(cat "$L/next")
echo "$NEXT" | tail -3; echo "next worker got: $NEXTP"
[ "$NEXTP" = "$SLOT" ] && echo "RESULT: idle slot REUSED" || echo "RESULT: slot NOT reused (new slot created)"
echo "next worker HEAD=$(git -C "$NEXTP" rev-parse --short HEAD 2>/dev/null) origin/main=$(git -C "$L/project" rev-parse --short origin/main)"
say "treehouse status"; (cd "$L/project" && treehouse status 2>&1)
rm -rf "$L"
