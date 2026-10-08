#!/usr/bin/env bash
# Shared base-freshen logic for Treehouse pool worktrees.
#
# Used by bin/fm-spawn.sh when a pool slot is allocated to a task, and by
# bin/fm-teardown.sh when an idle slot is returned to the pool after its work
# is proven landed. Keeping the logic in one place means spawn and teardown
# agree on what "freshly fetched default branch" means and on how a dirty slot
# is detected.
#
# Callers must provide a default_branch helper that accepts an optional worktree
# directory and prints the default branch name (origin/HEAD, main, or master).

# A pooled slot whose only deviation is a submodule gitlink is stale, not dirty:
# an earlier refresh moved the superproject and left the submodule checkout on
# the pin the previous base recorded. The refusal still stands and this gate
# never touches the slot; it only names the cause, because "is not clean" while
# the operator's own `git status` reads clean gives neither a cause nor a remedy.
# A pin is only reported as stale when the commit the slot holds is already
# contained in one of the submodule's remotes. Anything that cannot be proven
# contained - an unpushed commit, a submodule with no remote, a git error - falls
# through to the conservative uncommitted-work refusal, as does any entry that is
# not exactly a clean submodule sitting on a different pin. The diagnosis is
# buffered and only emitted once every entry qualifies, so it can never
# contradict the verdict.
#
# No remedy command is printed, deliberately. That containment check reads local
# refs only and never fetches, because this gate has to stay usable offline. A
# remote-tracking ref that has gone stale - its upstream branch deleted or
# force-pushed, and never pruned - therefore still reads as containment, so a
# commit that is really unpushed can look contained. Naming the submodule and both
# pins is what the operator actually needs; printing a checkout command on a
# judgement that can be fooled could cost them that commit, so the remedy is left
# to the operator, who can see the whole picture.
describe_stale_submodule_pins() { # <worktree> <status>
  local worktree=$1 status=$2 line path want have unpushed lines=
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case $line in ' M '*) path=${line#' M '} ;; *) return 1 ;; esac
    [ "$(git -C "$worktree" ls-files --stage -- "$path" 2>/dev/null | cut -c1-6)" = 160000 ] || return 1
    [ -z "$(git -C "$worktree/$path" status --porcelain 2>/dev/null)" ] || return 1
    want=$(git -C "$worktree" rev-parse --verify --quiet "HEAD:$path" 2>/dev/null) || return 1
    have=$(git -C "$worktree/$path" rev-parse --verify --quiet HEAD 2>/dev/null) || return 1
    [ "$want" != "$have" ] || return 1
    unpushed=$(git -C "$worktree/$path" log --format=%H --max-count=1 "$have" --not --remotes -- 2>/dev/null) || return 1
    [ -z "$unpushed" ] || return 1
    lines+="error: submodule '$path' is checked out at $have, but this base records $want"$'\n'
  done <<EOF
$status
EOF
  [ -n "$lines" ] || return 1
  printf '%s' "$lines" >&2
}

spawn_worktree_has_origin_config() { # <worktree>
  # Resolved remote.origin.* variables cover Git's effective include/includeIf chain; raw headers are also detected in the worktree config and any included file Git names through another variable. Git cannot enumerate a variable-less included file, so an empty origin section that is its only content remains indistinguishable from absence and intentionally proceeds rather than reimplementing Git's config parser.
  local worktree=$1 config origin key seen=$'\n'
  git -C "$worktree" config --get-regexp '^remote\.origin\.' >/dev/null 2>&1 && return 0
  while IFS=$'\t' read -r origin key; do
    case $origin in file:*) config=${origin#file:} ;; *) continue ;; esac
    [ -f "$config" ] || continue
    case $seen in *$'\n'"$config"$'\n'*) continue ;; esac
    seen+="$config"$'\n'
    awk '/^[[:space:]]*\[[[:space:]]*[Rr][Ee][Mm][Oo][Tt][Ee][[:space:]]+"origin"[[:space:]]*\][[:space:]]*([#;].*)?$/ || /^[[:space:]]*\[[[:space:]]*[Rr][Ee][Mm][Oo][Tt][Ee]\.origin[[:space:]]*\][[:space:]]*([#;].*)?$/ { found=1 } END { exit !found }' "$config" && return 0
  done < <(git -C "$worktree" config --list --show-origin 2>/dev/null || true)
  return 1
}

# Fetch the current origin default branch (or the supplied base branch) and
# reset a clean pooled worktree to it.
# Returns 1 when the worktree is dirty, has no origin, the fetch fails, or the
# reset cannot be verified. Never uses --force.
freshen_pool_worktree_base() { # <worktree> [<base-branch>]
  local worktree=$1 base=${2:-} default target expected actual status
  status=$(git -C "$worktree" -c core.quotePath=false status --porcelain) || {
    echo "error: could not inspect pooled worktree '$worktree' before refreshing its base" >&2
    return 1
  }
  if [ -n "$status" ]; then
    if describe_stale_submodule_pins "$worktree" "$status"; then
      echo "error: pooled worktree '$worktree' has a stale submodule checkout, not uncommitted work; refusing to refresh and leaving it untouched" >&2
    else
      echo "error: pooled worktree '$worktree' is not clean; refusing to discard uncommitted work while refreshing its base" >&2
    fi
    return 1
  fi
  if ! spawn_worktree_has_origin_config "$worktree"; then
    [ -z "$base" ] || {
      echo "error: pooled worktree '$worktree' has no origin, so it cannot start from base branch '$base'" >&2
      return 1
    }
    return 0
  fi
  if ! git -C "$worktree" fetch --quiet origin; then
    echo "error: could not fetch origin for pooled worktree '$worktree'; refusing to refresh from a potentially stale base" >&2
    return 1
  fi
  if [ -n "$base" ]; then
    default=$base
  else
    if ! git -C "$worktree" remote set-head origin --auto >/dev/null 2>&1; then
      echo "error: could not resolve origin's current default branch for pooled worktree '$worktree'; refusing to refresh from a potentially stale base" >&2
      return 1
    fi
    default=$(default_branch "$worktree") || {
      echo "error: could not determine origin's default branch for pooled worktree '$worktree'; refusing to refresh from a potentially stale base" >&2
      return 1
    }
  fi
  target="origin/$default"
  if ! git -C "$worktree" fetch --quiet origin "+refs/heads/$default:refs/remotes/origin/$default"; then
    echo "error: could not fetch '$target' for pooled worktree '$worktree'; refusing to refresh from a potentially stale base" >&2
    return 1
  fi
  expected=$(git -C "$worktree" rev-parse --verify --quiet "$target^{commit}" 2>/dev/null) || {
    echo "error: '$target' is not a commit for pooled worktree '$worktree'; refusing to refresh from a potentially stale base" >&2
    return 1
  }
  if ! git -C "$worktree" reset --hard "$target" >/dev/null; then
    echo "error: could not reset pooled worktree '$worktree' to '$target'; refusing to refresh from a potentially stale base" >&2
    return 1
  fi
  actual=$(git -C "$worktree" rev-parse --verify --quiet HEAD 2>/dev/null || true)
  if [ "$actual" != "$expected" ]; then
    echo "error: pooled worktree '$worktree' is at '${actual:-unknown}', not current '$target' ('$expected'); refusing to refresh" >&2
    return 1
  fi
}
