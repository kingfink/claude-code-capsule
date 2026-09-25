# Experimental auto mode: run `claude --dangerously-skip-permissions` against a
# throwaway copy of the current git checkout and of the identity volume, and
# bring the work back only as a patch that ccc-auto-apply applies after review.
# Sourced by ccc-identities.sh. See "Auto mode" in the README.
#
# Outbound network is NOT restricted yet, so ccc-run-auto is gated behind
# CCC_EXPERIMENTAL_AUTO=1.

# Variables ccc-run-auto sets or relies on; env files and -e can't override them.
_ccc_auto_reserved_env=(
  HOME PATH CLAUDE_CONFIG_DIR XDG_CONFIG_HOME ANTHROPIC_BASE_URL
  HTTP_PROXY HTTPS_PROXY NO_PROXY ALL_PROXY http_proxy https_proxy no_proxy all_proxy
)

_ccc_auto_data_root() { print -r -- "${XDG_DATA_HOME:-$HOME/.local/share}/ccc/auto-runs"; }

# Read a run's meta file (KEY=value lines written by ccc-run-auto) into the
# caller's associative array `meta`. Never sourced.
_ccc_auto_read_meta() {
  local line
  meta=()
  [[ -f "$1/meta" ]] || return 1
  while IFS= read -r line; do
    [[ "$line" == *=* ]] && meta[${line%%=*}]="${line#*=}"
  done < "$1/meta"
}

# Classify one changed path from the patch; prints a reason if it needs a close look.
_ccc_auto_flag_path() {
  # Match against "/path" so */x covers x at any depth and /x only at the root.
  case "/$1" in
    /.github/*|/.gitlab-ci.yml|/.circleci/*|/.buildkite/*|/.husky/*|*/.pre-commit-config.yaml)
      print "CI / git hooks" ;;
    */.claude/*|*/CLAUDE.md|*/CLAUDE.local.md|*/.mcp.json|/.devcontainer/*|/.vscode/*|/.idea/*)
      print "agent / editor config" ;;
    */.envrc|*/.env|*/.env.*|*/.npmrc|*/.yarnrc*|*/.tool-versions|*/.gitattributes|*/.gitmodules|*/.gitignore)
      print "environment / git config" ;;
    */Dockerfile*|*/*.dockerfile|*/docker-compose*.y*ml|*/compose.y*ml|*/.dockerignore)
      print "container config" ;;
    */Makefile|*/GNUmakefile|*/*.mk|*/justfile|*/Justfile|*/Taskfile.y*ml|*/Rakefile|*/build.rs|*/build.gradle*|*/pom.xml|*/CMakeLists.txt)
      print "build script" ;;
    */package.json|*/package-lock.json|*/npm-shrinkwrap.json|*/yarn.lock|*/pnpm-lock.yaml|*/pnpm-workspace.yaml|*/bun.lock*|*/pyproject.toml|*/setup.py|*/setup.cfg|*/requirements*.txt|*/Pipfile*|*/poetry.lock|*/uv.lock|*/Gemfile*|*/*.gemspec|*/Cargo.toml|*/Cargo.lock|*/go.mod|*/go.sum|*/composer.json|*/composer.lock)
      print "dependencies / package scripts" ;;
  esac
}

# Write the review report for a patch: flagged paths first, then per-file stats.
_ccc_auto_report() {
  emulate -L zsh
  setopt extended_glob
  local patch="$1" line p reason
  local -a numstat flagged modes
  local i n=0
  if [[ ! -s "$patch" ]]; then
    print "No changes."
    return
  fi
  numstat=(${(f)"$(git apply --numstat "$patch")"})
  # Each file's resulting mode, in patch order (the same order as --numstat), so
  # edited executables and symlinks are flagged, not only new ones. Header lines
  # can't be confused with hunk lines, which always start with a prefix character.
  while IFS= read -r line; do
    case "$line" in
      "diff --git "*) (( n++ )); modes[n]="" ;;
      "deleted file mode "*) modes[n]=deleted ;;
      "new file mode "*|"new mode "*) modes[n]="${line##* }" ;;
      "index "*" "*) [[ -z "${modes[n]}" ]] && modes[n]="${line##* }" ;;
    esac
  done < "$patch"
  for (( i = 1; i <= $#numstat; i++ )); do
    line="${numstat[i]}"
    p="${line#*$'\t'*$'\t'}"
    reason="$(_ccc_auto_flag_path "$p")"
    [[ "${line%%$'\t'*}" == "-" ]] && reason="${reason:+$reason, }binary"
    case "${modes[i]}" in
      100755) reason="${reason:+$reason, }executable" ;;
      120000) reason="${reason:+$reason, }symlink" ;;
    esac
    [[ -n "$reason" ]] && flagged+=("$p  ($reason)")
  done
  print "Files changed: $#numstat"
  (( n == $#numstat )) || print "Warning: couldn't read file modes from the patch; check executables and symlinks by hand."
  print
  if (( $#flagged )); then
    print "Flagged for close review (the whole patch is untrusted):"
    print -rl -- "  "${^flagged}
  else
    print "Nothing flagged (the whole patch is still untrusted)."
  fi
  print
  print "Changes (added/deleted lines, - for binary):"
  print -rl -- "  "${^numstat}
}

# Diff a finished run's scratch repo against its starting commit into
# <run dir>/changes.patch, then write report.txt. Also usable by hand to retry
# an export that failed: ccc-auto-export <run-id>.
ccc-auto-export() {
  emulate -L zsh
  local run_id="$1"
  local run_dir="$(_ccc_auto_data_root)/$run_id"
  local root="${functions_source[ccc-auto-export]:A:h:h}"
  local -A meta
  if [[ -z "$run_id" ]] || ! _ccc_auto_read_meta "$run_dir"; then
    print -u2 "usage: ccc-auto-export <run-id> (runs live in $(_ccc_auto_data_root))"
    return 1
  fi
  local repo_vol="ccc-auto-${run_id}-repo"
  if ! docker volume inspect "$repo_vol" >/dev/null 2>&1 || [[ ! -f "$run_dir/start.bundle" ]]; then
    print -u2 "ccc-auto-export: run $run_id has no scratch volume or bundle left to export"
    return 1
  fi
  docker run --rm --label ccc.auto=1 --label "ccc.auto.run=$run_id" \
    --network none --cap-drop=ALL --security-opt=no-new-privileges --pids-limit=128 \
    -v "$run_dir/start.bundle:/ccc/start.bundle:ro" \
    -v "$repo_vol:/ccc/agent:ro" \
    -v "$root/bin/ccc-auto-export.sh:/ccc/export.sh:ro" \
    -e "CCC_START=${meta[start]}" \
    --entrypoint sh ccc /ccc/export.sh > "$run_dir/changes.patch.tmp" || {
    rm -f "$run_dir/changes.patch.tmp"
    print -u2 "ccc-auto-export: export failed; scratch volume $repo_vol kept"
    return 1
  }
  mv "$run_dir/changes.patch.tmp" "$run_dir/changes.patch" || return 1
  _ccc_auto_report "$run_dir/changes.patch" > "$run_dir/report.txt" || return 1
  print -r -- "exported=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$run_dir/meta"
}

ccc-run-auto() {
  emulate -L zsh
  setopt extended_glob local_traps

  if [[ "${CCC_EXPERIMENTAL_AUTO:-}" != 1 ]]; then
    print -u2 "ccc-run-auto: experimental. Outbound network is not restricted yet, so the API key"
    print -u2 "and your source code can leave the capsule. Set CCC_EXPERIMENTAL_AUTO=1 to use it anyway."
    return 1
  fi
  if [[ -z "${1:-}" || "$1" == -* ]]; then
    print -u2 "usage: ccc-run-auto <name> [--memory X] [--cpus N] [--env-file F] [-e K[=V]] [-- command...]"
    return 1
  fi
  local name="$1"; shift
  if [[ ! "$name" =~ '^[A-Za-z0-9][A-Za-z0-9_.-]*$' ]]; then
    print -u2 "ccc-run-auto: invalid identity name: $name"
    return 1
  fi
  local root="${functions_source[ccc-run-auto]:A:h:h}"

  local -a docker_args cmd_args
  local sep=${@[(i)--]}
  docker_args=("${@[1,sep-1]}")
  (( sep <= $# )) && cmd_args=("${@[sep+1,-1]}")

  # Only resource limits and environment are accepted: anything else (-v,
  # --network, --cap-add, --privileged, ...) could undo the isolation.
  local -a run_args env_args env_keys env_vals
  local i=1 a flag v line key has_memory=0 has_cpus=0
  while (( i <= $#docker_args )); do
    a="${docker_args[i]}"
    case "$a" in
      --memory=*|--cpus=*|--env=*|--env-file=*) flag="${a%%=*}"; v="${a#*=}" ;;
      --memory|--cpus|--env|--env-file|-e)
        flag="$a"; (( i++ ))
        if (( i > $#docker_args )); then print -u2 "ccc-run-auto: $a needs a value"; return 1; fi
        v="${docker_args[i]}" ;;
      *)
        print -u2 "ccc-run-auto: docker argument not allowed in auto mode: ${a%%=*}"
        print -u2 "ccc-run-auto: allowed: --memory, --cpus, --env-file, -e/--env"
        return 1 ;;
    esac
    case "$flag" in
      --memory) run_args+=(--memory "$v"); has_memory=1 ;;
      --cpus) run_args+=(--cpus "$v"); has_cpus=1 ;;
      --env|-e)
        env_args+=(-e "$v")
        env_keys+=("${v%%=*}"); env_vals+=("$([[ "$v" == *=* ]] && print -r -- "=${v#*=}")") ;;
      --env-file)
        if [[ ! -f "$v" ]]; then print -u2 "ccc-run-auto: env file not found: $v"; return 1; fi
        env_args+=(--env-file "${v:A}")
        while IFS= read -r line || [[ -n "$line" ]]; do
          line="${line##[[:space:]]#}"
          [[ -z "$line" || "$line" == \#* ]] && continue
          key="${${line%%=*}%%[[:space:]]#}"
          env_keys+=("$key"); env_vals+=("$([[ "$line" == *=* ]] && print -r -- "=${line#*=}")")
        done < "$v" ;;
    esac
    (( i++ ))
  done
  (( has_memory )) || run_args+=(--memory "${CCC_MEMORY:-4g}")
  (( has_cpus )) || run_args+=(--cpus "${CCC_CPUS:-2}")

  # Vet environment keys (never their values): reserved names are refused,
  # likely secrets need CCC_AUTO_ALLOW_SECRETS=1, and an API key is expected.
  local -a secret_keys
  local have_api_key=0
  for (( i = 1; i <= $#env_keys; i++ )); do
    key="${env_keys[i]}"
    if (( ${_ccc_auto_reserved_env[(Ie)$key]} )); then
      print -u2 "ccc-run-auto: $key is set by auto mode and can't be overridden"
      return 1
    fi
    if [[ "$key" == ANTHROPIC_API_KEY ]]; then
      # KEY=value sets it; a bare KEY passes it through from the host shell.
      if [[ -n "${env_vals[i]#=}" ]] || { [[ -z "${env_vals[i]}" ]] && [[ -n "$(printenv ANTHROPIC_API_KEY)" ]]; }; then
        have_api_key=1
      fi
    elif [[ "${key:u}" == (*TOKEN*|*SECRET*|*PASSWORD*|*PASSWD*|*CREDENTIAL*|*PRIVATE*|*_KEY|*APIKEY*) ]]; then
      secret_keys+=("$key")
    fi
  done
  if (( $#secret_keys )); then
    if [[ "${CCC_AUTO_ALLOW_SECRETS:-}" != 1 ]]; then
      print -u2 "ccc-run-auto: refusing to pass likely secrets into an auto capsule: ${(j:, :)${(@u)secret_keys}}"
      print -u2 "ccc-run-auto: use a separate env file without them, or set CCC_AUTO_ALLOW_SECRETS=1"
      return 1
    fi
    print -u2 "ccc-run-auto: warning: passing secrets into the capsule: ${(j:, :)${(@u)secret_keys}}"
  fi
  if (( ! have_api_key )) && [[ "${CCC_AUTO_ALLOW_OAUTH:-}" != 1 ]]; then
    print -u2 "ccc-run-auto: auto mode expects ANTHROPIC_API_KEY (ideally one with a spend limit) via --env-file or -e."
    print -u2 "ccc-run-auto: to use the identity's OAuth login instead, set CCC_AUTO_ALLOW_OAUTH=1 (untested: a refresh"
    print -u2 "ccc-run-auto: inside the copy may log out the original identity)"
    return 1
  fi

  # The checkout must be a clean git repo; the capsule gets a clone of HEAD.
  local top start branch
  if ! top="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    print -u2 "ccc-run-auto: not inside a git repository"
    return 1
  fi
  if [[ "$top" == "$root" ]]; then
    print -u2 "ccc-run-auto: refusing to run on the capsule repo itself"
    return 1
  fi
  if ! start="$(git -C "$top" rev-parse --verify --quiet HEAD)"; then
    print -u2 "ccc-run-auto: $top has no commits"
    return 1
  fi
  if [[ -n "$(git -C "$top" status --porcelain --untracked-files=all)" ]]; then
    print -u2 "ccc-run-auto: $top has uncommitted or untracked changes; commit or stash them first"
    return 1
  fi
  if git -C "$top" ls-tree -r HEAD | grep -q '^160000 '; then
    print -u2 "ccc-run-auto: repositories with submodules aren't supported yet"
    return 1
  fi
  if git -C "$top" grep -q 'filter=lfs' HEAD -- ':(glob)**/.gitattributes' 2>/dev/null; then
    print -u2 "ccc-run-auto: warning: Git LFS isn't supported; LFS files will be pointer files in the capsule"
  fi
  branch="$(git -C "$top" symbolic-ref --quiet --short HEAD)"

  # The identity volume is copied, never mounted. Copying one that a running
  # capsule is writing to could give an inconsistent snapshot.
  local src_vol="ccc-${name}-config" have_src=0
  if docker volume inspect "$src_vol" >/dev/null 2>&1; then
    have_src=1
    if [[ -n "$(docker ps -q --filter "volume=$src_vol")" && "${CCC_AUTO_ALLOW_LIVE_COPY:-}" != 1 ]]; then
      print -u2 "ccc-run-auto: $src_vol is in use by a running container; exit it first"
      print -u2 "ccc-run-auto: (or set CCC_AUTO_ALLOW_LIVE_COPY=1 to copy it anyway)"
      return 1
    fi
  else
    print -u2 "ccc-run-auto: note: no $src_vol volume; starting with an empty Claude config"
  fi

  local run_id="$(date +%Y%m%d-%H%M%S)-$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 6)"
  local run_dir="$(_ccc_auto_data_root)/$run_id"
  local repo_vol="ccc-auto-${run_id}-repo" cfg_vol="ccc-auto-${run_id}-config"
  local agent="ccc-auto-${run_id}-agent" mount="/${top:t}"
  local -a labels=(--label ccc.auto=1 --label "ccc.auto.run=$run_id")
  local agent_ran=0 agent_status=0 exported=0

  (umask 077 && mkdir -p "$run_dir") || return 1
  # Written before the run so an export can be retried by hand if it fails.
  print -rl -- "run_id=$run_id" "identity=$name" "repo=$top" "branch=$branch" "start=$start" \
    "started=$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$run_dir/meta"

  trap 'return 130' INT TERM HUP
  {
    git -C "$top" bundle create --quiet "$run_dir/start.bundle" HEAD || return 1
    docker volume create "${labels[@]}" "$repo_vol" >/dev/null || return 1
    docker volume create "${labels[@]}" "$cfg_vol" >/dev/null || return 1

    # New volumes are root-owned; hand them to node (the only capability used).
    docker run --rm "${labels[@]}" --network none --user 0 \
      --cap-drop=ALL --cap-add=CHOWN --security-opt=no-new-privileges \
      -v "$repo_vol:/ccc/repo" -v "$cfg_vol:/ccc/config" \
      --entrypoint chown ccc node:node /ccc/repo /ccc/config || return 1

    local -a src_mount
    (( have_src )) && src_mount=(-v "$src_vol:/ccc/src:ro")
    docker run --rm "${labels[@]}" --network none \
      --cap-drop=ALL --security-opt=no-new-privileges --pids-limit=128 \
      -v "$run_dir/start.bundle:/ccc/start.bundle:ro" \
      -v "$repo_vol:/ccc/repo" -v "$cfg_vol:/ccc/config" "${src_mount[@]}" \
      -e "CCC_START=$start" -e "CCC_BRANCH=${branch:-ccc-auto}" -e "CCC_DROP_OAUTH=$have_api_key" \
      --entrypoint sh ccc -c '
        set -e
        [ -d /ccc/src ] && cp -a /ccc/src/. /ccc/config/
        [ "$CCC_DROP_OAUTH" = 1 ] && rm -f /ccc/config/.credentials.json
        cd /ccc/repo
        git init -q
        git fetch -q /ccc/start.bundle HEAD
        git checkout -q -B "$CCC_BRANCH" "$CCC_START"
        git config user.name "ccc auto" && git config user.email ccc-auto@localhost
      ' || return 1

    local setup="$root/setup/$name.sh"
    local -a setup_mount tty
    [[ -f "$setup" ]] && setup_mount=(-v "$setup:/ccc/setup.sh:ro")
    [[ -t 0 && -t 1 ]] && tty=(-t)
    (( $#cmd_args )) || cmd_args=(claude --dangerously-skip-permissions)

    print -u2 "ccc-run-auto: run $run_id on a scratch clone of $top at ${start[1,12]}"
    print -u2 "ccc-run-auto: warning: outbound network is unrestricted in this experimental build"
    agent_ran=1
    docker run -i "${tty[@]}" --rm --name "$agent" "${labels[@]}" \
      --cap-drop=ALL \
      --security-opt=no-new-privileges \
      --pids-limit=512 \
      "${run_args[@]}" \
      -v "$repo_vol:$mount" \
      -w "$mount" \
      -v "$cfg_vol:/home/node/.claude" \
      "${setup_mount[@]}" \
      "${env_args[@]}" \
      ccc "${cmd_args[@]}"
    agent_status=$?
    print -r -- "agent_exit=$agent_status" >> "$run_dir/meta"

    print -u2 "ccc-run-auto: exporting changes"
    ccc-auto-export "$run_id" || return 1
    exported=1
    print
    cat "$run_dir/report.txt"
    print
    print "Patch: $run_dir/changes.patch"
    print "Review it, then apply from $top with: ccc-auto-apply"
  } always {
    docker rm -f "$agent" >/dev/null 2>&1
    docker volume rm "$cfg_vol" >/dev/null 2>&1
    if (( exported || ! agent_ran )); then
      docker volume rm "$repo_vol" >/dev/null 2>&1
      rm -f "$run_dir/start.bundle"
      (( agent_ran )) || rm -rf "$run_dir"
    else
      print -u2 "ccc-run-auto: the run's changes were not exported; kept scratch volume $repo_vol"
      print -u2 "ccc-run-auto: retry with: ccc-auto-export $run_id   (ccc-auto-gc removes it)"
    fi
  }
  return $agent_status
}

# Apply a run's patch to the current checkout after showing the review report.
# Picks the latest run for this repository unless a run id is given. Never
# commits, runs or pushes anything.
ccc-auto-apply() {
  emulate -L zsh
  autoload -Uz is-at-least
  local top run_dir d
  local -A meta
  if ! top="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    print -u2 "ccc-auto-apply: not inside a git repository"
    return 1
  fi
  local data_root="$(_ccc_auto_data_root)"
  if [[ -n "${1:-}" ]]; then
    run_dir="$data_root/$1"
    if ! _ccc_auto_read_meta "$run_dir"; then print -u2 "ccc-auto-apply: no run $1"; return 1; fi
    if [[ "${meta[repo]}" != "$top" ]]; then
      print -u2 "ccc-auto-apply: run $1 was for ${meta[repo]}, not $top"
      return 1
    fi
  else
    # Newest unapplied run with a patch; say which newer runs have none yet.
    local -a unexported
    for d in "$data_root"/*(N/On); do
      _ccc_auto_read_meta "$d" && [[ "${meta[repo]}" == "$top" ]] || continue
      [[ -f "$d/applied" ]] && continue
      if [[ -f "$d/changes.patch" ]]; then run_dir="$d"; break; fi
      unexported+=("${d:t}")
    done
    (( $#unexported )) && print -u2 "ccc-auto-apply: skipping newer run(s) with no exported patch: ${(j:, :)unexported} (see ccc-auto-export)"
    if [[ -z "$run_dir" ]]; then print -u2 "ccc-auto-apply: no unapplied auto runs with a patch for $top"; return 1; fi
  fi

  if [[ -f "$run_dir/applied" ]]; then
    print -u2 "ccc-auto-apply: run ${meta[run_id]} was already applied"
    return 1
  fi
  if [[ ! -f "$run_dir/changes.patch" ]]; then
    print -u2 "ccc-auto-apply: run ${meta[run_id]} has no exported patch (try: ccc-auto-export ${meta[run_id]})"
    return 1
  fi
  if [[ ! -s "$run_dir/changes.patch" ]]; then
    print "ccc-auto-apply: run ${meta[run_id]} made no changes"
    return 0
  fi
  # Older git apply can write through symlinks (CVE-2023-23946).
  local git_version="${${(s: :)$(git version)}[3]}"
  if ! is-at-least 2.39.2 "$git_version"; then
    print -u2 "ccc-auto-apply: needs git 2.39.2 or newer (found $git_version)"
    return 1
  fi
  if [[ -n "$(git -C "$top" status --porcelain --untracked-files=all)" ]]; then
    print -u2 "ccc-auto-apply: $top has uncommitted or untracked changes; commit or stash them first"
    return 1
  fi
  if [[ "$(git -C "$top" rev-parse HEAD)" != "${meta[start]}" ]]; then
    print -u2 "ccc-auto-apply: HEAD has moved since run ${meta[run_id]} started; check out ${meta[start][1,12]} first"
    return 1
  fi

  # Once on disk, an agent-written .gitattributes makes host git (git status,
  # diff, checkout, and possibly apply itself) run filter and diff drivers
  # configured on this machine, e.g. git-lfs or textconv, on the agent's files.
  # -i because macOS filesystems are usually case-insensitive.
  if git apply --numstat "$run_dir/changes.patch" | cut -f3- | grep -qiE '(^"?|/)\.gitattributes"?$'; then
    print -u2 "ccc-auto-apply: the patch changes .gitattributes, which can make git run filter or diff"
    print -u2 "ccc-auto-apply: commands configured on this machine. Review it and apply it by hand if you trust it:"
    print -u2 "  git apply $run_dir/changes.patch"
    return 1
  fi

  print "Run ${meta[run_id]} (identity ${meta[identity]}, started ${meta[started]}, exit ${meta[agent_exit]:-?})"
  print
  cat "$run_dir/report.txt"
  print
  git -C "$top" apply --stat --summary "$run_dir/changes.patch" || return 1
  if ! git -C "$top" apply --check "$run_dir/changes.patch"; then
    print -u2 "ccc-auto-apply: patch does not apply cleanly"
    return 1
  fi
  print
  print "Full patch: $run_dir/changes.patch"
  if ! read -q "?Apply these changes to $top? [y/N] "; then
    print
    return 1
  fi
  print
  git -C "$top" apply "$run_dir/changes.patch" || return 1
  date -u +%Y-%m-%dT%H:%M:%SZ > "$run_dir/applied"
  print "Applied. Nothing is committed: review with git status / git diff, then commit and push as usual."
}

# Remove auto-mode containers and volumes left behind by crashes or failed
# exports. Only touches resources labeled ccc.auto, never identity volumes.
ccc-auto-gc() {
  emulate -L zsh
  local -a containers running volumes unexported
  local v run_dir
  containers=(${(f)"$(docker ps -aq --filter label=ccc.auto=1 --filter status=exited --filter status=created --filter status=dead)"})
  running=(${(f)"$(docker ps -q --filter label=ccc.auto=1)"})
  (( $#containers )) && docker rm -f "${containers[@]}" >/dev/null
  (( $#running )) && print "ccc-auto-gc: leaving ${#running} running auto container(s) and their volumes alone"

  # A scratch repo volume holds unexported work unless its run has a patch.
  volumes=(${(f)"$(docker volume ls -q --filter label=ccc.auto=1)"})
  for v in ${(M)volumes:#ccc-auto-*-repo}; do
    run_dir="$(_ccc_auto_data_root)/${${v#ccc-auto-}%-repo}"
    [[ -f "$run_dir/changes.patch" ]] || unexported+=("$v")
  done
  if (( $#unexported )); then
    print "Scratch volumes with unexported work: ${(j:, :)unexported}"
    if read -q "?Delete them? [y/N] "; then
      print
    else
      print
      volumes=(${volumes:|unexported})
    fi
  fi
  for v in "${volumes[@]}"; do
    [[ -n "$(docker ps -q --filter "volume=$v")" ]] && continue
    docker volume rm "$v" >/dev/null && print "removed $v"
  done

  # Bundles are only needed while a scratch volume exists to export.
  for run_dir in "$(_ccc_auto_data_root)"/*(N/); do
    [[ -f "$run_dir/start.bundle" ]] || continue
    docker volume inspect "ccc-auto-${run_dir:t}-repo" >/dev/null 2>&1 || rm -f "$run_dir/start.bundle"
  done
}
