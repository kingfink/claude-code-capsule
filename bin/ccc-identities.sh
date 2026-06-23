ccc-run() {
  if [[ -z "$1" ]]; then
    echo "usage: ccc-run <name> [extra docker args...]" >&2
    return 1
  fi
  local name="$1"; shift
  local -a resource_args
  local arg has_memory_arg=0 has_cpus_arg=0
  for arg in "$@"; do
    case "$arg" in
      --memory|--memory=*|-m|-m*) has_memory_arg=1 ;;
      --cpus|--cpus=*) has_cpus_arg=1 ;;
    esac
  done
  [[ "$has_memory_arg" == 0 ]] && resource_args+=(--memory "${CCC_MEMORY:-4g}")
  [[ "$has_cpus_arg" == 0 ]] && resource_args+=(--cpus "${CCC_CPUS:-2}")
  case "$PWD" in
    "$HOME"|/) echo "ccc-run: refusing to mount $PWD — cd into a project dir first" >&2; return 1 ;;
  esac
  docker run -it --rm \
    --cap-drop=ALL \
    --security-opt=no-new-privileges \
    --pids-limit=512 \
    "${resource_args[@]}" \
    -v "$(pwd):/workspace" \
    -v "ccc-${name}-config:/home/node/.claude" \
    "$@" \
    ccc
}

# Build (or rebuild) the image, then sweep the now-dangling previous image and
# stale build cache so rebuilds don't pile up untagged layers. Finds the repo
# root from this file's own location, so it works from any directory.
ccc-build() {
  local self="${functions_source[ccc-build]}"
  docker build -t ccc "${self:A:h:h}" "$@" && docker image prune -f && docker builder prune -f
}

# Real per-identity wrappers live in an untracked file next to this one.
_ccc_identities_dir="${${(%):-%x}:A:h}"
[[ -f "$_ccc_identities_dir/ccc-identities.local.sh" ]] && \
  source "$_ccc_identities_dir/ccc-identities.local.sh"
unset _ccc_identities_dir
