#!/usr/bin/env bash
# Live driver: a REAL agy worker in a throwaway Herdr lab session, exited and
# relaunched through the real bin/fm-control.sh.
#
#   usage: drive-agy-herdr-exit.sh <worktree-root> <base-bin-root> <evidence-dir>
#
# <base-bin-root> is a checkout of the base commit (holding bin/), used to
# reproduce the pre-fix refusal on the same live pane before the fixed
# fm-control is run against it.
set -u
ROOT=$1
BASE=$2
EV=$3

say() { printf '\n=== %s\n' "$*"; }
die() { printf 'DRIVER-FAIL: %s\n' "$*"; exit 1; }

# shellcheck source=/dev/null
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
unset FM_GATE_REFUSE_BYPASS NO_MISTAKES_GATE FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE

SESSION=$("$ROOT/bin/fm-herdr-lab.sh" name agyexit)
export HERDR_SESSION="$SESSION"
SCRATCH=
cleanup() {
  say "teardown"
  "$ROOT/bin/fm-herdr-lab.sh" teardown "$SESSION" && echo "lab session $SESSION torn down, default-session tripwire intact"
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
}
trap cleanup EXIT

# provision runs the prepare step (default-session tripwire) itself for a new name.
say "provision lab session $SESSION"
"$ROOT/bin/fm-herdr-lab.sh" provision "$SESSION" || die "provision"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); SCRATCH=$(cd "$SCRATCH" && pwd -P)
HOME_DIR="$SCRATCH/home"
"$ROOT/bin/fm-lab-home.sh" create "$HOME_DIR" || die "lab home create"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/agyx"
cat > "$HOME_DIR/data/agyx/brief.md" <<'EOF'
# Task
## Captain's intent
Live validation fixture. Do not change any file.

## Firstmate spec
Reply with the single word READY and then wait. Do not run any tool and do not edit anything.
EOF

PROJ="$SCRATCH/proj"; WT="$SCRATCH/wt"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b agyx "$WT"

# Throwaway HOME with a copy of the agy store (docs/verification/agy.md), so
# the trust answer never lands in the operator's real store.
AGY_HOME="$SCRATCH/agyhome"
mkdir -p "$AGY_HOME"
cp -R "$HOME/.gemini" "$AGY_HOME/.gemini" || die "stage agy store"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || die "source herdr backend"

CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || die "container_ensure"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
WORKSPACE_ID=${CONTAINER#*:}
read -r TAB_ID PANE_ID <<EOF
$(fm_backend_herdr_create_task "$CONTAINER" "fm-agyx" "$WT" "$SEEDED_TAB_ID")
EOF
[ -n "$PANE_ID" ] || die "create_task"
TARGET="$SESSION:$PANE_ID"
{
  echo "window=$TARGET"
  echo "endpoint_task_id=agyx"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=agy"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$TAB_ID"
  echo "herdr_pane_id=$PANE_ID"
} > "$HOME_DIR/state/agyx.meta"

screen() { fm_backend_herdr_visible_capture "$TARGET" 2>/dev/null || true; }
agent_json() { herdr agent get "$PANE_ID" --session "$SESSION" 2>&1; }
snap() {  # <label>
  { printf -- '--- rendered pane (%s)\n' "$1"; screen | grep -v '^[[:space:]]*$' | tail -14
    printf -- '--- herdr agent get: %s\n' "$(agent_json | jq -c '.result.agent | {agent, agent_status}' 2>/dev/null || agent_json | tr -d '\n')"
    printf -- '--- fm_backend_agent_state: %s\n' "$(fm_backend_agent_state herdr "$TARGET")"
    printf -- '--- fm_backend_herdr_composer_state: %s\n' "$(fm_backend_herdr_composer_state "$TARGET")"
  }
}

say "launch REAL agy $(agy --version 2>/dev/null | head -1) in lab pane $TARGET"
printf -v AGY_HOME_Q '%q' "$AGY_HOME"
fm_backend_herdr_send_text_line "$TARGET" \
  "HOME=$AGY_HOME_Q agy --prompt-interactive \"Add 12345 and 67890. Reply with exactly the sum and nothing else\" --model gemini-3.8-flash-low --effort low --dangerously-skip-permissions" \
  || die "launch agy"
s=
for _ in $(seq 1 150); do
  s=$(screen)
  case "$s" in *"Do you trust the contents of this project?"*|*80235*|*80,235*) break ;; esac
  sleep 0.5
done
case "$s" in *"Do you trust the contents of this project?"*)
  echo "answering agy folder-trust dialog (throwaway store)"
  fm_backend_herdr_send_key "$TARGET" Enter || die "trust answer" ;;
esac

if [ "${DRIVE_BUSY_CASE:-1}" = 1 ]; then
  # Adversarial, in flight: while the real turn is running the composer must
  # NOT read empty.
  busy_seen=
  for _ in $(seq 1 240); do
    s=$(screen)
    case "$s" in *"esc to cancel"*) busy_seen=1; break ;; *80235*|*80,235*) break ;; esac
    sleep 0.3
  done
  if [ -n "$busy_seen" ]; then
    say "ADVERSARIAL: real agy mid-turn"
    snap "mid-turn"
  else
    echo "note: the busy row was not caught before the reply rendered"
  fi
fi

for _ in $(seq 1 480); do
  s=$(screen)
  case "$s" in *80235*|*80,235*) break ;; esac
  sleep 0.5
done
case "$s" in *80235*|*80,235*) : ;; *) screen | tail -30; die "agy never answered its launch prompt" ;; esac
for _ in $(seq 1 120); do
  s=$(screen)
  case "$s" in *"? for shortcuts"*) break ;; esac
  sleep 0.5
done
# Herdr's native status settles shortly after the rendered footer.
for _ in $(seq 1 60); do
  st=$(agent_json | jq -r '.result.agent.agent_status // empty' 2>/dev/null)
  case "$st" in idle|done) break ;; esac
  sleep 0.5
done

say "settled idle REAL agy worker"
snap "settled idle"
fm_backend_herdr_visible_capture_ansi "$TARGET" > "$EV/agy-idle-pane.ansi" 2>/dev/null || true

run_control() {  # <root> <args...>
  local root=$1; shift
  env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
    "$root/bin/fm-control.sh" "$@" 2>&1
}

say "ADVERSARIAL: a half-typed draft in the real agy composer must still refuse (fixed code)"
fm_backend_herdr_send_literal "$TARGET" "half-typed draft" || die "type draft"
sleep 1.5
snap "draft typed"
out=$(run_control "$ROOT" agyx exit); rc=$?
printf 'fm-control.sh agyx exit (HEAD, draft in composer) -> rc=%s\n%s\n' "$rc" "$out"
echo "agent state after refused exit: $(fm_backend_agent_state herdr "$TARGET")"
DRAFT_RC=$rc
# Clear the draft the way a human would.
fm_backend_herdr_send_key "$TARGET" C-u || die "clear draft"
sleep 1.5
snap "draft cleared"

say "BASELINE (base commit 9601909): fm-control exit against the idle real agy worker"
out=$(run_control "$BASE" agyx exit); rc=$?
printf 'fm-control.sh agyx exit (BASE) -> rc=%s\n%s\n' "$rc" "$out"
echo "agent state after base exit attempt: $(fm_backend_agent_state herdr "$TARGET")"
BASE_RC=$rc

if [ "${DRIVE_RELAUNCH:-0}" = 1 ]; then
  say "FIXED (HEAD): fm-control relaunch --harness claude against the idle real agy worker"
  out=$(run_control "$ROOT" agyx relaunch --harness claude --note "Validation fixture: reply READY and wait.") ; rc=$?
  printf 'fm-control.sh agyx relaunch --harness claude (HEAD) -> rc=%s\n%s\n' "$rc" "$out"
  HEAD_RC=$rc
  sleep 8
  snap "after relaunch"
  echo "--- meta after relaunch"; grep -E '^(harness|window|model|effort)=' "$HOME_DIR/state/agyx.meta"
  echo "--- pane foreground processes: $(herdr pane process-info --pane "$PANE_ID" --session "$SESSION" 2>/dev/null | jq -c '[.result.process_info.foreground_processes[]?.name]' 2>/dev/null)"
  # Stop the replacement so the lab leaves nothing running.
  out=$(run_control "$ROOT" agyx exit); printf 'cleanup exit of the replacement -> rc=%s\n%s\n' "$?" "$out"
else
  say "FIXED (HEAD): fm-control exit against the idle real agy worker"
  out=$(run_control "$ROOT" agyx exit); rc=$?
  printf 'fm-control.sh agyx exit (HEAD) -> rc=%s\n%s\n' "$rc" "$out"
  HEAD_RC=$rc
  snap "after exit"
  echo "--- pane foreground processes: $(herdr pane process-info --pane "$PANE_ID" --session "$SESSION" 2>/dev/null | jq -c '[.result.process_info.foreground_processes[]?.name]' 2>/dev/null)"
  [ -d "$WT" ] && echo "worktree preserved: yes"
  herdr pane get "$PANE_ID" --session "$SESSION" >/dev/null 2>&1 && echo "endpoint preserved: yes"
  say "idempotence: second exit"
  out=$(run_control "$ROOT" agyx exit); printf 'rc=%s\n%s\n' "$?" "$out"
fi

say "RESULT draft_rc=$DRAFT_RC base_rc=$BASE_RC head_rc=$HEAD_RC"
