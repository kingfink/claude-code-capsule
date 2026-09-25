# Auto mode: run Claude in auto mode (or with --dangerously-skip-permissions)
# against a throwaway copy of the current git checkout and of the identity
# volume, and bring the work back only as a patch that you apply after review.
# The agent sits on an internal Docker network whose only way out is an egress
# proxy (ccc-auto-proxy.js) that holds the API key. Sourced by
# ccc-identities.sh; see "Auto mode" in the README.

# Variables ccc-run-auto sets or relies on; the env file can't override them.
_ccc_auto_reserved_env=(
  HOME PATH CLAUDE_CONFIG_DIR XDG_CONFIG_HOME
  ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC
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
  if [[ ! "$run_id" =~ '^[0-9]{8}-[0-9]{6}-[a-z0-9]{6}$' ]]; then
    print -u2 "usage: ccc-auto-apply <run-id>   (runs live in $(_ccc_auto_data_root))"
    return 1
  fi
  local run_dir="$(_ccc_auto_data_root)/$run_id"
  local root="${functions_source[ccc-auto-apply]:A:h:h}"
  local patch="$run_dir/changes.patch" repo_vol="ccc-auto-${run_id}-repo" top start
  if [[ ! -f "$run_dir/start" ]]; then
    print -u2 "ccc-auto-apply: no run $run_id"
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
      print -u2 "ccc-auto-apply: retry with: ccc-auto-apply $run_id"
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
  print

  local later="ccc-auto-apply: apply later from the repo with: ccc-auto-apply $run_id"
  # An agent-written .gitattributes would pick which of your configured filter
  # and diff drivers (git-lfs, textconv, ...) run on which files. -i because
  # macOS filesystems are usually case-insensitive.
  if git apply --numstat "$patch" | cut -f3- | grep -qiE '(^"?|/)\.gitattributes"?$'; then
    print -u2 "ccc-auto-apply: the patch changes .gitattributes, which picks the filter and diff commands"
    print -u2 "ccc-auto-apply: your git runs. Review it and apply it by hand if you trust it:"
    print -u2 "  git apply ${(q-)patch}"
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
  print "Read the full patch first: ${(q-)patch}"
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

  if (( $# < 2 )) || [[ -n "${3:-}" && "$3" != -- ]]; then
    print -u2 "usage: ccc-run-auto <name> <env-file> [-- command...]"
    return 1
  fi
  local name="$1" env_file="${2:A}"
  local -a cmd_args=("${@[4,-1]}")
  if [[ ! "$name" =~ '^[A-Za-z0-9][A-Za-z0-9_.-]*$' ]]; then
    print -u2 "ccc-run-auto: invalid identity name: $name"
    return 1
  fi
  local root="${functions_source[ccc-run-auto]:A:h:h}"

  # The env file must hold ANTHROPIC_API_KEY, which goes to the egress proxy
  # only; every other line goes to the agent. Keys are vetted, never their
  # values: reserved names and likely secrets are refused, since an auto
  # capsule shouldn't hold credentials. A bare KEY passes the host's value
  # through.
  if [[ ! -f "$env_file" || ! -r "$env_file" ]]; then
    print -u2 "ccc-run-auto: env file not found or not readable: $2"
    return 1
  fi
  local line key api_key=
  local -a secret_keys agent_env
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line##[[:space:]]#}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    key="${${line%%=*}%%[[:space:]]#}"
    if (( ${_ccc_auto_reserved_env[(Ie)$key]} )); then
      print -u2 "ccc-run-auto: $key is set by auto mode and can't be overridden"
      return 1
    elif [[ "$key" == ANTHROPIC_API_KEY ]]; then
      # As with docker, the last one wins.
      if [[ "$line" == *=* ]]; then
        api_key="${line#*=}"
      else
        api_key="$(printenv ANTHROPIC_API_KEY)"
      fi
      continue
    elif [[ "${key:u}" == (*TOKEN*|*SECRET*|*PASSWORD*|*PASSWD*|*CREDENTIAL*|*PRIVATE*|*_KEY|*APIKEY*) ]]; then
      secret_keys+=("$key")
    fi
    agent_env+=("$line")
  done < "$env_file"
  if (( $#secret_keys )); then
    print -u2 "ccc-run-auto: refusing to pass likely secrets into an auto capsule: ${(j:, :)${(@u)secret_keys}}"
    print -u2 "ccc-run-auto: give it an env file with only ANTHROPIC_API_KEY (and non-secret settings)"
    return 1
  fi
  if [[ -z "$api_key" ]]; then
    print -u2 "ccc-run-auto: the env file must set a non-empty ANTHROPIC_API_KEY (ideally a key with a spend limit)"
    return 1
  fi

  # Hosts the agent may reach over HTTPS, besides the API: exact names or
  # *.suffix, separated by spaces or commas.
  local host
  local -a allow_hosts=(${(L)=${CCC_AUTO_ALLOW_HOSTS:-}//,/ })
  for host in "${allow_hosts[@]}"; do
    if [[ ! "$host" =~ '^(\*\.)?[a-z0-9-]+(\.[a-z0-9-]+)+$' ]]; then
      print -u2 "ccc-run-auto: invalid CCC_AUTO_ALLOW_HOSTS entry: $host (use names like example.com or *.example.com)"
      return 1
    elif [[ "$host" == (api.anthropic.com|\*.anthropic.com) ]]; then
      # The proxy forwards API calls with your key. A direct tunnel would let
      # the agent send your code to someone else's account.
      print -u2 "ccc-run-auto: $host can't be in CCC_AUTO_ALLOW_HOSTS: a direct connection to the API would let the agent use other API keys"
      return 1
    fi
  done

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
  branch="$(git -C "$top" symbolic-ref --quiet --short HEAD)"

  # The identity volume is copied, never mounted. Copying one that a running
  # capsule is writing to could give an inconsistent snapshot.
  local src_vol="ccc-${name}-config"
  local -a src_mount
  if docker volume inspect "$src_vol" >/dev/null 2>&1; then
    src_mount=(-v "$src_vol:/ccc/src:ro")
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
  local agent="ccc-auto-${run_id}-agent" proxy="ccc-auto-${run_id}-proxy"
  local int_net="ccc-auto-${run_id}-internal" egress_net="ccc-auto-${run_id}-egress"
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

    # Seed both volumes. Each is first mounted over a node-owned dir in the
    # image, which makes the new volume node-owned too.
    docker run --rm "${labels[@]}" --network none \
      --cap-drop=ALL --security-opt=no-new-privileges --pids-limit=128 \
      -v "$run_dir/start.bundle:/ccc/start.bundle:ro" \
      -v "$repo_vol:/workspace" -v "$cfg_vol:/home/node/.claude" "${src_mount[@]}" \
      -e "CCC_START=$start" -e "CCC_BRANCH=${branch:-ccc-auto}" \
      --entrypoint sh ccc -c '
        set -e
        [ -d /ccc/src ] && cp -a /ccc/src/. /home/node/.claude/
        rm -f /home/node/.claude/.credentials.json
        cd /workspace
        git init -q
        git fetch -q /ccc/start.bundle HEAD
        git checkout -q -B "$CCC_BRANCH" "$CCC_START"
        git config user.name "ccc auto" && git config user.email ccc-auto@localhost
      ' || return 1

    # The agent's only network is internal: no route out, no outside DNS. The
    # proxy is on it (as ccc-proxy) and on a per-run egress network of its own.
    # It gets the API key from its environment, never from argv.
    docker network create --internal "${labels[@]}" "$int_net" >/dev/null || return 1
    docker network create "${labels[@]}" "$egress_net" >/dev/null || return 1
    ANTHROPIC_API_KEY="$api_key" docker run -d --name "$proxy" "${labels[@]}" \
      --network "$int_net" --network-alias ccc-proxy \
      --cap-drop=ALL --security-opt=no-new-privileges --read-only \
      --pids-limit=64 --memory 512m \
      -v "$root/bin/ccc-auto-proxy.js:/ccc/proxy.js:ro" \
      -e ANTHROPIC_API_KEY -e "CCC_AUTO_ALLOW_HOSTS=${(j: :)allow_hosts}" \
      --entrypoint node ccc /ccc/proxy.js >/dev/null || return 1
    docker network connect "$egress_net" "$proxy" || return 1
    local i
    for i in {1..100}; do
      docker logs "$proxy" 2>&1 | grep -q '^listening' && break
      if (( i == 100 )); then
        print -u2 "ccc-run-auto: the egress proxy didn't start:"
        docker logs "$proxy" >&2
        return 1
      fi
      sleep 0.1
    done
    local proxy_url=http://ccc-proxy:8080
    local -a proxy_env=(
      -e "ANTHROPIC_BASE_URL=$proxy_url" -e ANTHROPIC_AUTH_TOKEN=ccc-proxy-adds-the-key
      -e "HTTPS_PROXY=$proxy_url" -e "https_proxy=$proxy_url" -e "HTTP_PROXY=$proxy_url" -e "http_proxy=$proxy_url"
      -e NO_PROXY=ccc-proxy,localhost,127.0.0.1 -e no_proxy=ccc-proxy,localhost,127.0.0.1
      -e CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
    )
    (umask 077 && print -rl -- "${agent_env[@]}" > "$run_dir/agent.env") || return 1

    local setup="$root/setup/$name.sh"
    local -a setup_mount tty
    [[ -f "$setup" ]] && setup_mount=(-v "$setup:/ccc/setup.sh:ro")
    [[ -t 0 && -t 1 ]] && tty=(-t)
    (( $#cmd_args )) || cmd_args=(claude --permission-mode auto)

    print -u2 "ccc-run-auto: run $run_id on a scratch clone of $top at ${start[1,12]}"
    print -u2 "ccc-run-auto: network: the Anthropic API${allow_hosts:+, and HTTPS to ${(j:, :)allow_hosts}}"
    agent_ran=1
    docker run -i "${tty[@]}" --rm --name "$agent" "${labels[@]}" \
      --cap-drop=ALL \
      --security-opt=no-new-privileges \
      --pids-limit=512 \
      --memory "${CCC_MEMORY:-4g}" \
      --cpus "${CCC_CPUS:-2}" \
      --network "$int_net" \
      -v "$repo_vol:/${top:t}" \
      -w "/${top:t}" \
      -v "$cfg_vol:/home/node/.claude" \
      "${setup_mount[@]}" \
      --env-file "$run_dir/agent.env" \
      "${proxy_env[@]}" \
      ccc "${cmd_args[@]}"
    agent_status=$?

    docker logs "$proxy" > "$run_dir/proxy.log" 2>&1
    local -a blocked=(${(u)${(f)"$(sed -n 's/^deny CONNECT \([^ ]*\) .*/\1/p' "$run_dir/proxy.log")"}})
    if (( $#blocked )); then
      print -u2 "ccc-run-auto: blocked: ${(j:, :)blocked}"
      print -u2 "ccc-run-auto: (allow hosts with CCC_AUTO_ALLOW_HOSTS; log: $run_dir/proxy.log)"
    fi

    apply_ran=1
    ccc-auto-apply "$run_id" || return 1
  } always {
    docker rm -f "$agent" >/dev/null 2>&1
    (( agent_ran )) && [[ ! -f "$run_dir/proxy.log" ]] && docker logs "$proxy" > "$run_dir/proxy.log" 2>&1
    docker rm -f "$proxy" >/dev/null 2>&1
    docker network rm "$int_net" "$egress_net" >/dev/null 2>&1
    rm -f "$run_dir/agent.env"
    docker volume rm "$cfg_vol" >/dev/null 2>&1
    if (( ! agent_ran )); then
      docker volume rm "$repo_vol" >/dev/null 2>&1
      rm -rf "$run_dir"
    elif (( ! apply_ran )) && [[ ! -f "$run_dir/changes.patch" ]]; then
      print -u2 "ccc-run-auto: the run's changes were not exported; kept scratch volume $repo_vol"
      print -u2 "ccc-run-auto: export and apply with: ccc-auto-apply $run_id"
    fi
  }
  return $agent_status
}
