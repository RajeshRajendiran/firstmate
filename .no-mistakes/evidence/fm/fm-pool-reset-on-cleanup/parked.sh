set -u
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@x GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@x
L=$(mktemp -d /tmp/nmlive/parked.XXXX); L=$(cd -P $L && pwd -P)
git init -q --bare $L/origin.git; git -C $L/origin.git symbolic-ref HEAD refs/heads/main
git clone -q $L/origin.git $L/seed 2>/dev/null; echo b > $L/seed/R; git -C $L/seed add R; git -C $L/seed commit -qm b; git -C $L/seed push -q origin main
git clone -q $L/origin.git $L/project; git -C $L/project remote set-head origin main
export TREEHOUSE_ROOT=$L/pool
SLOT=$(cd $L/project && treehouse get --lease 2>/dev/null)
echo f > $SLOT/f; git -C $SLOT add f; git -C $SLOT commit -qm pre-squash; PRE=$(git -C $SLOT rev-parse HEAD); git -C $SLOT push -q origin HEAD:refs/heads/fm/t1
git clone -q $L/origin.git $L/land; git -C $L/land merge -q --squash origin/fm/t1 >/dev/null; git -C $L/land commit -qm squash; git -C $L/land push -q origin main
(cd $L/project && treehouse return --force $SLOT >/dev/null 2>&1)
git -C $L/land push -q origin --delete fm/t1; git -C $L/project fetch -q --prune origin; git -C $SLOT checkout -q --detach $PRE   # parked state: squash-merged, PR branch auto-deleted
echo "\$ treehouse status   (slot parked on pre-squash $(git -C $SLOT rev-parse --short HEAD))"; (cd $L/project && treehouse status)
echo "\$ treehouse get   (interactive, in a pane like a crewmate spawn)"; mkdir -p $L/tmux; export TMUX_TMPDIR=$L/tmux
tmux -L fm-lab new-session -d -s p -x 200 -y 50 -c $L/project -e TREEHOUSE_ROOT=$L/pool "bash --norc"; sleep 1
tmux -L fm-lab send-keys -t p "treehouse get" Enter; sleep 4; tmux -L fm-lab send-keys -t p "pwd > $L/got" Enter; sleep 1
tmux -L fm-lab capture-pane -p -t p | grep -v "^$" | tail -3; N=$(cat $L/got); echo "got $N"; tmux -L fm-lab kill-server; sleep 1
[ "$N" = "$SLOT" ] && echo "RESULT: parked slot reused" || echo "RESULT: parked slot NOT reused - a new slot was created"
(cd $L/project && treehouse return --force $N >/dev/null 2>&1)
echo "\$ freshen_pool_worktree_base <parked slot>   (the shared reset the teardown now runs)"
bash -c 'default_branch(){ local r; r=$(git -C "${1:-.}" symbolic-ref --quiet --short refs/remotes/origin/HEAD) && echo "${r#origin/}"; }; . "$1/bin/fm-treehouse-base-lib.sh"; freshen_pool_worktree_base "$2" && echo reset-ok' _ /home/agent/.no-mistakes/worktrees/37339719b87e/01M4D450FTE0YHQXSSAZNW1W5B $SLOT
echo "slot HEAD now $(git -C $SLOT rev-parse --short HEAD) ($(git -C $SLOT rev-parse --abbrev-ref HEAD)), origin/main $(git -C $SLOT rev-parse --short origin/main)"
echo "\$ treehouse get --lease"; N2=$(cd $L/project && treehouse get --lease 2>/dev/null); echo "got $N2"
[ "$N2" = "$SLOT" ] && echo "RESULT: reset slot reused" || echo "RESULT: reset slot NOT reused"
(cd $L/project && treehouse status); rm -rf $L
