#!/usr/bin/env bash
#
# Merge an upstream Lago release into this fork while keeping the fork's changes.
#
# Usage: scripts/sync-upstream.sh <upstream-tag>     e.g. scripts/sync-upstream.sh v1.54.0
#
# Run from the root of a clean checkout of the lago fork. The script is safe to
# re-run: after resolving a conflict it stops on, commit the resolution and run
# it again with the same tag. It never pushes; it prints the push commands.
#
# Steps:
#   1. Superproject: branch sync/<tag> off origin/main and merge the upstream tag.
#   2. api and front: branch sync/<tag> off origin/fps and merge the commit the
#      upstream tag pins for that submodule.
#   3. Point the superproject at the merged submodule commits and commit.
#   4. Warn about premium integrations upstream added that the fork does not enable.
#
# Exit codes: 0 done, 1 usage or precondition error, 2 conflicts to resolve by hand.
# UPSTREAM_LAGO, UPSTREAM_API and UPSTREAM_FRONT override the upstream URLs (used by tests).

set -euo pipefail

readonly UPSTREAM_LAGO="${UPSTREAM_LAGO:-https://github.com/getlago/lago.git}"
readonly UPSTREAM_API="${UPSTREAM_API:-https://github.com/getlago/lago-api.git}"
readonly UPSTREAM_FRONT="${UPSTREAM_FRONT:-https://github.com/getlago/lago-front.git}"
readonly FORK_BRANCH="fps"

die() {
  echo "error: $*" >&2
  exit 1
}

stop_for_conflicts() {
  echo >&2
  echo "Conflicts to resolve in $1:" >&2
  git -C "$1" diff --name-only --diff-filter=U | sed 's/^/  /' >&2
  echo >&2
  if [ "$1" = "." ]; then
    # The superproject merge is committed by this script once the submodules are merged.
    echo "Resolve them and 'git add' the files (do not commit)," >&2
  else
    echo "Resolve them, 'git -C $1 add' the files, 'git -C $1 commit --no-edit'," >&2
  fi
  echo "then re-run: scripts/sync-upstream.sh $TAG" >&2
  exit 2
}

merging() {
  git -C "$1" rev-parse -q --verify MERGE_HEAD >/dev/null
}

ensure_remote() {
  local dir=$1 url=$2
  if git -C "$dir" remote get-url upstream >/dev/null 2>&1; then
    git -C "$dir" remote set-url upstream "$url"
  else
    git -C "$dir" remote add upstream "$url"
  fi
}

# Switch $dir to branch $BRANCH, creating it from $base when it does not exist yet.
switch_to_sync_branch() {
  local dir=$1 base=$2
  if [ "$(git -C "$dir" branch --show-current)" = "$BRANCH" ]; then
    return
  fi
  if git -C "$dir" rev-parse -q --verify "refs/heads/$BRANCH" >/dev/null; then
    git -C "$dir" switch -q "$BRANCH"
  else
    git -C "$dir" switch -q -c "$BRANCH" "$base"
  fi
}

# Fetch a submodule's remotes and make sure its fps branch contains the commit
# origin/main pins, so the sync starts from the fork's changes and not an older base.
prepare_submodule() {
  local sub=$1 url=$2 pinned_sha
  pinned_sha=$(git rev-parse "origin/main:$sub")

  ensure_remote "$sub" "$url"
  git -C "$sub" fetch -q upstream
  git -C "$sub" fetch -q origin
  git -C "$sub" merge-base --is-ancestor "$pinned_sha" "origin/$FORK_BRANCH" ||
    die "$sub: origin/$FORK_BRANCH does not contain the pinned commit ${pinned_sha:0:12}; publish it to $FORK_BRANCH first"
}

sync_submodule() {
  local sub=$1 upstream_sha=$2

  echo "==> $sub: merging upstream ${upstream_sha:0:12}"
  if merging "$sub"; then
    stop_for_conflicts "$sub"
  fi
  switch_to_sync_branch "$sub" "origin/$FORK_BRANCH"

  if git -C "$sub" merge-base --is-ancestor "$upstream_sha" HEAD; then
    echo "    already merged"
    return
  fi
  git -C "$sub" merge -q --no-edit -m "chore: merge upstream $TAG" "$upstream_sha" || stop_for_conflicts "$sub"
}

# Print premium integrations declared by the model but absent from every fork migration
# that enables them. Such integrations stay locked until a new migration enables them.
check_premium_integrations() {
  local declared enabled
  local -a migrations missing
  declared=$(sed -n '/^  PREMIUM_INTEGRATIONS = %w\[/,/\]/p' api/app/models/organization.rb | sed '1d;$d' | tr -d ' ' | sort -u)
  shopt -s nullglob
  migrations=(api/db/migrate/*_enable_*premium_integrations*.rb)
  shopt -u nullglob
  enabled=""
  if [ "${#migrations[@]}" -gt 0 ]; then
    enabled=$(sed -n '/PREMIUM_INTEGRATIONS = %w\[/,/\]/p' "${migrations[@]}" | { grep -v '[][]' || true; } | tr -d ' ' | sort -u)
  fi
  mapfile -t missing < <(comm -23 <(echo "$declared") <(echo "$enabled") | sed '/^$/d')
  if [ "${#missing[@]}" -gt 0 ]; then
    echo
    echo "WARNING: upstream added premium integrations the fork does not enable yet:"
    printf '  %s\n' "${missing[@]}"
    echo "Add an api/db/migrate/<timestamp>_enable_new_premium_integrations.rb migration"
    echo "(see docs/fork_maintenance.md)."
  fi
}

[ $# -eq 1 ] || die "usage: scripts/sync-upstream.sh <upstream-tag>"
TAG=$1
BRANCH="sync/$TAG"

[ -f .gitmodules ] && [ -f docker/Dockerfile ] || die "run from the root of the lago fork"

echo "==> lago: fetching upstream $TAG"
ensure_remote . "$UPSTREAM_LAGO"
git fetch -q --no-recurse-submodules upstream "refs/tags/$TAG:refs/tags/$TAG" || die "upstream tag $TAG not found"
git fetch -q --no-recurse-submodules origin

if ! merging .; then
  [ -z "$(git status --porcelain --ignore-submodules=all)" ] || die "working tree is not clean"
  switch_to_sync_branch . origin/main
  git submodule update -q --init
fi

prepare_submodule api "$UPSTREAM_API"
prepare_submodule front "$UPSTREAM_FRONT"

upstream_api=$(git rev-parse "$TAG:api")
upstream_front=$(git rev-parse "$TAG:front")

if ! merging . && ! git merge-base --is-ancestor "$TAG" HEAD; then
  git merge -q --no-commit --no-ff "$TAG" >/dev/null 2>&1 || true
fi
# Submodule pointer conflicts are expected and settled below; anything else is not.
other_conflicts=$(git diff --name-only --diff-filter=U | grep -vxE 'api|front' || true)
if [ -n "$other_conflicts" ]; then
  stop_for_conflicts .
fi

sync_submodule api "$upstream_api"
sync_submodule front "$upstream_front"

git add api front
if merging .; then
  git commit -q --no-edit -m "chore: merge upstream $TAG"
elif ! git diff --cached --quiet; then
  git commit -q -m "chore: point submodules at merged $TAG"
fi

check_premium_integrations

cat <<EOF

Done. Branch $BRANCH is ready in lago, api and front.

Next steps (see docs/fork_maintenance.md):
  1. Run the API specs, at least:
       spec/models/organization_spec.rb spec/lib/lago_utils/license_spec.rb
  2. Publish the submodules first (fast-forward only, keeps the pinned commits reachable):
       git -C api push origin $BRANCH:$FORK_BRANCH
       git -C front push origin $BRANCH:$FORK_BRANCH
  3. Push the superproject and open a PR into main:
       git push -u origin $BRANCH
  4. After merging, build and push the image with the new tag.
EOF
