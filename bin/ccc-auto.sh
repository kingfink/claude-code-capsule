# Experimental auto mode: run Claude in auto mode (or with
# --dangerously-skip-permissions) against a throwaway copy of the current git
# checkout and of the identity volume, and bring the work back only as a patch
# that you apply after review. Sourced by ccc-identities.sh; see "Auto mode" in
# the README.
#
# Outbound network is NOT restricted yet, so ccc-run-auto is gated behind
# CCC_EXPERIMENTAL_AUTO=1.

# Variables ccc-run-auto sets or relies on; env files and -e can't override them.
_ccc_auto_reserved_env=(
  HOME PATH CLAUDE_CONFIG_DIR XDG_CONFIG_HOME ANTHROPIC_BASE_URL
  HTTP_PROXY HTTPS_PROXY NO_PROXY ALL_PROXY http_proxy https_proxy no_proxy all_proxy
)

_ccc_auto_data_root() { print -r -- "${XDG_DATA_HOME:-$HOME/.local/share}/ccc/auto-runs"; }

# Export a run's changes if that hasn't happened yet, then offer to apply the
# patch to the current checkout. ccc-run-auto calls this when the agent exits;
# run it by hand to retry a failed export or to apply a patch you declined.
# Never commits, runs or pushes anything.
ccc-auto-apply() {
  emulate -L zsh
  autoload -Uz is-at-least
  local run_id="${1:-}"
  local run_dir="$(_ccc_auto_data_root)/$run_id"
  local root="${functions_source[ccc-auto-apply]:A:h:h}"
  local patch="$run_dir/changes.patch" repo_vol="ccc-auto-${run_id}-repo" top start
  if [[ -z "$run_id" || ! -f "$run_dir/start" ]]; then
    print -u2 "usage: ccc-auto-apply <run-id>   (runs live in $(_ccc_auto_data_root))"
    return 1
  fi
  start="$(<"$run_dir/start")"

  if [[ ! -f "$patch" ]]; then
    # Diff the agent's files against the starting commit in a network-less
    # container, using a fresh .git (see ccc-auto-export.sh). The patch comes
    # back on stdout, so the exporter never writes to the host.
    if ! docker volume inspect "$repo_vol" >/dev/null 2>&1 || [[ ! -f "$run_dir/start.bundle" ]]; then
      print -u2 "ccc-auto-apply: run $run_id has no patch and no scratch volume left to export"
      return 1
    fi
    docker run --rm --label ccc.auto=1 --label "ccc.auto.run=$run_id" \
      --network none --cap-drop=ALL --security-opt=no-new-privileges --pids-limit=128 \
      -v "$run_dir/start.bundle:/ccc/start.bundle:ro" \
      -v "$repo_vol:/ccc/agent:ro" \
      -v "$root/bin/ccc-auto-export.sh:/ccc/export.sh:ro" \
      -e "CCC_START=$start" \
      --entrypoint sh ccc /ccc/export.sh > "$patch.tmp" && mv "$patch.tmp" "$patch" || {
      rm -f "$patch.tmp"
      print -u2 "ccc-auto-apply: export failed; kept scratch volume $repo_vol"
      print -u2 "ccc-auto-apply: retry with: ccc-auto-apply $run_id   (ccc-auto-gc removes it)"
      return 1
    }
    docker volume rm "$repo_vol" >/dev/null
    rm -f "$run_dir/start.bundle"
  fi

  if [[ ! -s "$patch" ]]; then
    print "ccc-auto-apply: run $run_id made no changes"
    return 0
  fi
  print
  git apply --stat --summary "$patch" || return 1
  print "Patch: $patch"
  print

  local later="ccc-auto-apply: apply later from the repo with: ccc-auto-apply $run_id"
  # An agent-written .gitattributes would pick which of your configured filter
  # and diff drivers (git-lfs, textconv, ...) run on which files. -i because
  # macOS filesystems are usually case-insensitive.
  if git apply --numstat "$patch" | cut -f3- | grep -qiE '(^"?|/)\.gitattributes"?$'; then
    print -u2 "ccc-auto-apply: the patch changes .gitattributes, which picks the filter and diff commands"
    print -u2 "ccc-auto-apply: your git runs. Review it and apply it by hand if you trust it: git apply $patch"
    return 1
  fi
  # Older git apply can write through symlinks (CVE-2023-23946).
  local git_version="${${(s: :)$(git version)}[3]}"
  if ! is-at-least 2.39.2 "$git_version"; then
    print -u2 "ccc-auto-apply: needs git 2.39.2 or newer (found $git_version)"
    return 1
  fi
  if ! top="$(git rev-parse --show-toplevel 2>/dev/null)" || [[ "$(git -C "$top" rev-parse HEAD)" != "$start" ]]; then
    print -u2 "ccc-auto-apply: run from the run's repository with ${start[1,12]} checked out"
    print -u2 "$later"
    return 1
  fi
  if [[ -n "$(git -C "$top" status --porcelain --untracked-files=all)" ]]; then
    print -u2 "ccc-auto-apply: $top has uncommitted or untracked changes"
    print -u2 "$later"
    return 1
  fi
  if ! git -C "$top" apply --check "$patch"; then
    print -u2 "ccc-auto-apply: patch does not apply cleanly"
    return 1
  fi
  if ! read -q "?Apply these changes to $top? [y/N] "; then
    print
    print "$later"
    return 0
  fi
  print
  git -C "$top" apply "$patch" || return 1
  print "Applied. Nothing is committed: review with git status / git diff, then commit as usual."
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

  # Vet environment keys (never their values): reserved names and likely
  # secrets are refused (the network isn't restricted yet), and an API key is
  # expected.
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
    print -u2 "ccc-run-auto: refusing to pass likely secrets into an auto capsule: ${(j:, :)${(@u)secret_keys}}"
    print -u2 "ccc-run-auto: give it an env file with only ANTHROPIC_API_KEY (and non-secret settings)"
    return 1
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
  local agent_ran=0 agent_status=0 apply_ran=0

  (umask 077 && mkdir -p "$run_dir") || return 1
  # ccc-auto-apply reads the starting commit from here.
  print -r -- "$start" > "$run_dir/start"

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
    (( $#cmd_args )) || cmd_args=(claude --permission-mode auto)

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

    apply_ran=1
    ccc-auto-apply "$run_id" || return 1
  } always {
    docker rm -f "$agent" >/dev/null 2>&1
    docker volume rm "$cfg_vol" >/dev/null 2>&1
    if (( ! agent_ran )); then
      docker volume rm "$repo_vol" >/dev/null 2>&1
      rm -rf "$run_dir"
    elif (( ! apply_ran )) && [[ ! -f "$run_dir/changes.patch" ]]; then
      print -u2 "ccc-run-auto: the run's changes were not exported; kept scratch volume $repo_vol"
      print -u2 "ccc-run-auto: export and apply with: ccc-auto-apply $run_id   (ccc-auto-gc removes it)"
    fi
  }
  return $agent_status
}

# Remove auto-mode containers and volumes left behind by crashes or failed
# exports. Only touches resources labeled ccc.auto, never identity volumes.
ccc-auto-gc() {
  emulate -L zsh
  local -a containers volumes
  local v
  containers=(${(f)"$(docker ps -aq --filter label=ccc.auto=1 --filter status=exited --filter status=created --filter status=dead)"})
  volumes=(${(f)"$(docker volume ls -q --filter label=ccc.auto=1)"})
  if (( ! $#containers && ! $#volumes )); then
    print "ccc-auto-gc: nothing to clean up"
    return 0
  fi
  (( $#containers )) && print "Stopped auto-mode containers: $#containers"
  (( $#volumes )) && print -rl -- "Volumes:" "  "${^volumes}
  (( ${#${(M)volumes:#*-repo}} )) && print "Scratch (-repo) volumes may hold work that was never exported (ccc-auto-apply <run-id> exports it)."
  if ! read -q "?Remove them? [y/N] "; then
    print
    return 1
  fi
  print
  (( $#containers )) && docker rm -f "${containers[@]}" >/dev/null
  for v in "${volumes[@]}"; do
    if [[ -n "$(docker ps -q --filter "volume=$v")" ]]; then
      print "skipping $v (in use)"
      continue
    fi
    docker volume rm "$v" >/dev/null || continue
    print "removed $v"
    # A failed export keeps its bundle; it's useless once the volume is gone.
    [[ "$v" == *-repo ]] && rm -f "$(_ccc_auto_data_root)/${${v#ccc-auto-}%-repo}/start.bundle"
  done
}
