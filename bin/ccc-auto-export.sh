#!/bin/sh
# Runs in a throwaway, network-less container after a ccc-run-auto session.
# Diffs the agent's working tree (mounted read-only at /ccc/agent) against the
# recorded starting commit ($CCC_START), using a fresh git directory built from
# the original bundle. Nothing in the agent-controlled .git (config, hooks,
# history) is read or run, and .gitattributes filter/diff drivers do nothing
# because their definitions would have to come from this fresh repo's config.
# Git never adds entries named .git, so the agent's own .git is skipped.
#
# Writes a binary-capable patch to stdout. Newly created files ignored by the
# final .gitignore are left out, like `git add -A` on the host would.
set -eu

export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null HOME=/tmp

repo=$(mktemp -d)
git init -q "$repo"
g() { git --git-dir="$repo/.git" --work-tree=/ccc/agent "$@"; }

git --git-dir="$repo/.git" fetch -q /ccc/start.bundle HEAD
g read-tree "$CCC_START"
g add -A

# A nested repository would be recorded as a gitlink, not its files.
nested=$(g ls-files -s | awk '$1 == "160000" { print $4 }')
if [ -n "$nested" ]; then
  echo "ccc-auto-export: nested git repositories are not supported:" >&2
  echo "$nested" >&2
  exit 3
fi

g diff --cached --binary --full-index --no-renames --no-color "$CCC_START"
