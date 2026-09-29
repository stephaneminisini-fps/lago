#!/usr/bin/env bash
#
# Tests for scripts/sync-upstream.sh against small local repositories that mimic
# the upstream Lago repos and the FPS forks. No network access.
#
# Usage: tests/sync_upstream_test.sh

set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/scripts/sync-upstream.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Allow file:// submodules and give commits an identity without touching user config.
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
export GIT_CONFIG_KEY_1=init.defaultBranch GIT_CONFIG_VALUE_1=main
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

export UPSTREAM_LAGO="$WORK/up-lago" UPSTREAM_API="$WORK/up-api" UPSTREAM_FRONT="$WORK/up-front"

failures=0
pass() { echo "ok   - $1"; }
fail() {
  echo "FAIL - $1" >&2
  [ -f "${out:-}" ] && sed 's/^/     | /' "$out" >&2
  failures=$((failures + 1))
}
check() {
  local name=$1
  shift
  if "$@"; then pass "$name"; else fail "$name"; fi
}

organization_rb() {
  printf '  PREMIUM_INTEGRATIONS = %%w[\n'
  printf '    %s\n' "$@"
  printf '  ].freeze\n'
}

commit_all() {
  git -C "$1" add -A
  git -C "$1" commit -q -m "$2"
}

# --- Upstream v1 -----------------------------------------------------------
setup_upstream_v1() {
  git init -q "$UPSTREAM_API"
  mkdir -p "$UPSTREAM_API/app/models"
  organization_rb okta xero >"$UPSTREAM_API/app/models/organization.rb"
  echo "upstream" >"$UPSTREAM_API/license.rb"
  printf 'schema\nv1\n' >"$UPSTREAM_API/structure.sql"
  commit_all "$UPSTREAM_API" "api v1"

  git init -q "$UPSTREAM_FRONT"
  echo "front v1" >"$UPSTREAM_FRONT/index.ts"
  commit_all "$UPSTREAM_FRONT" "front v1"

  git init -q "$UPSTREAM_LAGO"
  mkdir -p "$UPSTREAM_LAGO/docker"
  echo "FROM scratch" >"$UPSTREAM_LAGO/docker/Dockerfile"
  echo "readme v1" >"$UPSTREAM_LAGO/README.md"
  git -C "$UPSTREAM_LAGO" submodule -q add "$UPSTREAM_API" api
  git -C "$UPSTREAM_LAGO" submodule -q add "$UPSTREAM_FRONT" front
  commit_all "$UPSTREAM_LAGO" "lago v1"
  git -C "$UPSTREAM_LAGO" tag v1
}

# --- Forks: fps branches carry the fork's changes -------------------------
setup_forks() {
  git clone -q --bare "$UPSTREAM_API" "$WORK/fork-api"
  git clone -q "$WORK/fork-api" "$WORK/tmp-api"
  git -C "$WORK/tmp-api" switch -q -c fps
  echo "fork" >"$WORK/tmp-api/license.rb"
  mkdir -p "$WORK/tmp-api/db/migrate"
  organization_rb okta xero >"$WORK/tmp-api/db/migrate/1_enable_all_premium_integrations.rb"
  printf 'schema\nv1\nfork migration\n' >"$WORK/tmp-api/structure.sql"
  commit_all "$WORK/tmp-api" "fork: unlock"
  git -C "$WORK/tmp-api" push -q origin fps

  git clone -q --bare "$UPSTREAM_FRONT" "$WORK/fork-front"
  git -C "$WORK/fork-front" branch fps main

  git clone -q --bare "$UPSTREAM_LAGO" "$WORK/fork-lago"
  git clone -q --recurse-submodules "$WORK/fork-lago" "$WORK/tmp-lago" 2>/dev/null
  git -C "$WORK/tmp-lago" config -f .gitmodules submodule.api.url "$WORK/fork-api"
  git -C "$WORK/tmp-lago" config -f .gitmodules submodule.front.url "$WORK/fork-front"
  git -C "$WORK/tmp-lago" submodule -q sync
  git -C "$WORK/tmp-lago/api" fetch -q origin fps
  git -C "$WORK/tmp-lago/api" checkout -q FETCH_HEAD
  echo "readme fork" >"$WORK/tmp-lago/README.md"
  commit_all "$WORK/tmp-lago" "fork: point at forks"
  git -C "$WORK/tmp-lago" push -q origin main
}

# --- Upstream v2: conflicts in README.md and api/structure.sql, new integration
setup_upstream_v2() {
  organization_rb okta xero hubspot >"$UPSTREAM_API/app/models/organization.rb"
  printf 'schema\nv1\nupstream v2 migration\n' >"$UPSTREAM_API/structure.sql"
  commit_all "$UPSTREAM_API" "api v2"
  echo "front v2" >"$UPSTREAM_FRONT/index.ts"
  commit_all "$UPSTREAM_FRONT" "front v2"

  git -C "$UPSTREAM_LAGO/api" pull -q origin main
  git -C "$UPSTREAM_LAGO/front" pull -q origin main
  echo "readme v2" >"$UPSTREAM_LAGO/README.md"
  commit_all "$UPSTREAM_LAGO" "lago v2"
  git -C "$UPSTREAM_LAGO" tag v2
}

setup_upstream_v1
setup_forks
setup_upstream_v2

git clone -q --recurse-submodules "$WORK/fork-lago" "$WORK/lago" 2>/dev/null
cd "$WORK/lago"
out="$WORK/out.txt"

# 1. Superproject conflict: stops with exit 2 and asks not to commit.
status=0
"$SCRIPT" v2 >"$out" 2>&1 || status=$?
check "stops with exit 2 on a superproject conflict" test "$status" -eq 2
check "reports README.md as conflicting" grep -q "README.md" "$out"
check "asks not to commit the superproject" grep -q "do not commit" "$out"

echo "readme fork v2" >README.md
git add README.md

# 2. Submodule conflict: stops with exit 2 in api.
status=0
"$SCRIPT" v2 >"$out" 2>&1 || status=$?
check "stops with exit 2 on an api conflict" test "$status" -eq 2
check "reports api/structure.sql as conflicting" grep -q "structure.sql" "$out"

printf 'schema\nv1\nupstream v2 migration\nfork migration\n' >api/structure.sql
git -C api add structure.sql
git -C api commit -q --no-edit

# 3. Completes, merging everything.
status=0
"$SCRIPT" v2 >"$out" 2>&1 || status=$?
check "completes with exit 0 after resolving" test "$status" -eq 0
check "superproject contains upstream v2" git merge-base --is-ancestor v2 HEAD
check "superproject merge is committed" test -z "$(git status --porcelain)"
check "api pointer contains upstream api v2" git -C api merge-base --is-ancestor "$(git -C "$UPSTREAM_API" rev-parse main)" "$(git rev-parse HEAD:api)"
check "api pointer keeps the fork's changes" git -C api merge-base --is-ancestor "$(git -C "$WORK/fork-api" rev-parse fps)" "$(git rev-parse HEAD:api)"
check "fork license change survives" test "$(git -C api show HEAD:license.rb)" = "fork"
check "front pointer is upstream front v2" test "$(git rev-parse HEAD:front)" = "$(git -C "$UPSTREAM_FRONT" rev-parse main)"
check "warns about the new hubspot integration" grep -q "^  hubspot$" "$out"
check "does not warn about enabled integrations" bash -c "! grep -qE '^  (okta|xero)$' '$out'"
check "does not push anything" test "$(git -C "$WORK/fork-lago" rev-parse main)" = "$(git rev-parse origin/main)"

# 4. Re-running is a no-op.
head_before=$(git rev-parse HEAD)
status=0
"$SCRIPT" v2 >"$out" 2>&1 || status=$?
check "re-run exits 0" test "$status" -eq 0
check "re-run creates no commit" test "$(git rev-parse HEAD)" = "$head_before"

# 5. Refuses when the fps branch lacks the pinned commit.
git clone -q --recurse-submodules "$WORK/fork-lago" "$WORK/lago2" 2>/dev/null
git -C "$WORK/fork-api" update-ref refs/heads/fps "$(git -C "$UPSTREAM_API" rev-parse main~1)"
status=0
(cd "$WORK/lago2" && "$SCRIPT" v2 >"$out" 2>&1) || status=$?
check "refuses when fps lacks the pinned commit" test "$status" -eq 1
check "explains the missing pinned commit" grep -q "does not contain the pinned commit" "$out"

# 6. Usage errors.
status=0
"$SCRIPT" >"$out" 2>&1 || status=$?
check "exits 1 without a tag" test "$status" -eq 1
status=0
(cd "$WORK" && "$SCRIPT" v2 >"$out" 2>&1) || status=$?
check "exits 1 outside the repository root" test "$status" -eq 1
status=0
(cd "$WORK/lago2" && "$SCRIPT" v404 >"$out" 2>&1) || status=$?
check "exits 1 for an unknown tag" test "$status" -eq 1

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
