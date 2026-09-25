#!/usr/bin/env zsh
# Integration test for ccc-run-auto and ccc-auto-apply. Needs Docker and the
# ccc image (ccc-build). The "agent" is a shell command or a stub claude, so no
# API calls are made. Everything it creates is removed at the end, also on
# Ctrl-C.
#
#   zsh test/auto.zsh

emulate -R zsh
setopt extended_glob

repo_root="${0:A:h:h}"
tmp="$(mktemp -d)"
export XDG_DATA_HOME="$tmp/data" CCC_EXPERIMENTAL_AUTO=1
ident="ccctest-$$"
src_vol="ccc-$ident-config"
env_file="$tmp/auto.env"
source "$repo_root/bin/ccc-identities.sh"

fails=0
check() {  # check <description> <command...>
  if "${@[2,-1]}" >/dev/null 2>&1; then print "ok    $1"; else print "FAIL  $1"; (( fails++ )); fi
}
has() { [[ "$1" == *"$2"* ]]; }
runs_dir() { print -r -- "$XDG_DATA_HOME/ccc/auto-runs"; }
last_run() { print -r -- "$(runs_dir)"/*(N/om[1]:t); }
leftovers() {  # labeled containers and volumes belonging to this test's runs
  local d
  for d in "$(runs_dir)"/*(N/:t); do
    docker ps -aq --filter "label=ccc.auto.run=$d"
    docker volume ls -q --filter "label=ccc.auto.run=$d"
  done
}
no_leftovers() { [[ -z "$(leftovers)" ]]; }
git_dir_sum() { (cd .git && find . -type f -exec cksum {} + | sort | cksum); }
clean_tree() { [[ -z "$(git status --porcelain --untracked-files=all)" ]]; }
reset_tree() { git reset -q --hard && git clean -qfdx; }
# Run a command in a fresh zsh on a pseudo-terminal, answering $1 to prompts.
pty() {
  local cmd="source ${(q)repo_root}/bin/ccc-identities.sh; $2"
  if script --version >/dev/null 2>&1; then
    print -r -- "$1" | script -qec "zsh -c ${(q)cmd}" /dev/null
  else
    print -r -- "$1" | script -q /dev/null zsh -c "$cmd"
  fi
}
cleanup() {
  local -a ids=(${(f)"$(leftovers)"})
  (( $#ids )) && { docker rm -f "${ids[@]}"; docker volume rm -f "${ids[@]}"; } >/dev/null 2>&1
  docker volume rm -f "$src_vol" >/dev/null 2>&1
  rm -rf "$tmp"
}
trap 'cleanup; exit 130' INT TERM HUP

# An identity with an OAuth login and a stub claude that prints its arguments.
docker run --rm -v "$src_vol:/home/node/.claude" ccc sh -c '
  echo oauth > ~/.claude/.credentials.json
  mkdir -p ~/.claude/bin
  printf "#!/bin/sh\necho claude-args: \"\$*\"\n" > ~/.claude/bin/claude
  chmod +x ~/.claude/bin/claude' || { cleanup; exit 1; }
print "ANTHROPIC_API_KEY=test" > "$env_file"

mkdir "$tmp/proj" && cd "$tmp/proj" && git init -q
echo keep > keep.txt; echo gone > gone.txt; printf '#!/bin/sh\necho 1\n' > tool.sh; chmod +x tool.sh
git add -A && git -c user.name=t -c user.email=t@t commit -qm init

print "== default command"
out="$(ccc-run-auto "$ident" "$env_file" 2>&1)"
check "runs claude in auto mode" has "$out" "claude-args: --permission-mode auto"
check "no changes, nothing left behind" no_leftovers
out="$(ccc-run-auto "$ident" "$env_file" -- claude --dangerously-skip-permissions 2>&1)"
check "bypass command passes through" has "$out" "claude-args: --dangerously-skip-permissions"

print "== run, decline, apply later"
before="$(git_dir_sum)"
out="$(ccc-run-auto "$ident" "$env_file" -- sh -c '
  test ! -e ~/.claude/.credentials.json && echo creds-removed
  mkdir -p ~/.claude/bin && echo planted > ~/.claude/bin/gh
  echo more >> keep.txt; rm gone.txt; echo new > new.txt
  printf "a\000b" > blob.bin; ln -s keep.txt link; printf "#!/bin/sh\necho 2\n" > tool.sh
  git add -A && git commit -qm agent && echo uncommitted > later.txt
  git config core.fsmonitor "touch /tmp/pwned"' 2>&1)"
run="$(last_run)"
check "OAuth login stripped from the copy" has "$out" creds-removed
check "patch exported" test -s "$(runs_dir)/$run/changes.patch"
check "declined without a terminal" has "$out" "ccc-auto-apply $run"
check "host .git unchanged" test "$before" = "$(git_dir_sum)"
check "checkout untouched" clean_tree
check "nothing left behind" no_leftovers
out="$(pty n "ccc-auto-apply $run")"
check "answering n leaves the checkout alone" clean_tree
out="$(pty y "ccc-auto-apply $run")"
check "answering y applies" has "$out" "Applied."
check "edit, delete, new and uncommitted files applied" \
  test "$(<keep.txt)" = $'keep\nmore' -a ! -e gone.txt -a -f new.txt -a -f later.txt
check "binary, symlink and executable applied" \
  test "$(od -c blob.bin | head -1)" = "$(printf 'a\000b' | od -c | head -1)" -a -L link -a -x tool.sh
reset_tree
out="$(ccc-run-auto "$ident" "$env_file" -- sh -c 'test ! -e ~/.claude/bin/gh && echo identity-clean' 2>&1)"
check "planted file didn't persist in the identity" has "$out" identity-clean

print "== failed export, then retry"
out="$(ccc-run-auto "$ident" "$env_file" -- sh -c 'echo x > locked; chmod 000 locked' 2>&1)"
run="$(last_run)"
check "export failure reported" has "$out" "export failed"
check "scratch volume kept" docker volume inspect "ccc-auto-$run-repo"
docker run --rm -v "ccc-auto-$run-repo:/w" ccc chmod 644 /w/locked
out="$(pty y "ccc-auto-apply $run")"
check "retry exports and applies" test -f locked
check "scratch volume removed after export" no_leftovers
reset_tree

print "== refusals"
out="$(ccc-run-auto "$ident" "$env_file" -- sh -c 'mkdir sub && echo "* filter=x" > sub/.GitAttributes' 2>&1)"
check ".gitattributes patch refused" has "$out" "changes .gitattributes"
check "  and not applied" clean_tree
ccc-run-auto "$ident" "$env_file" -- sh -c 'echo z > z.txt' >/dev/null 2>&1
run="$(last_run)"
git -c user.name=t -c user.email=t@t commit -q --allow-empty -m moved
out="$(pty y "ccc-auto-apply $run")"
check "moved HEAD refused" has "$out" "checked out"
git reset -q --hard HEAD~1
echo dirty > untracked.txt
check "dirty checkout refused" test -n "$(ccc-run-auto "$ident" "$env_file" 2>&1 | grep uncommitted)"
rm untracked.txt
check "extra docker arguments refused" has "$(ccc-run-auto "$ident" "$env_file" --privileged 2>&1)" usage
check "missing env file refused" has "$(ccc-run-auto "$ident" "$tmp/nope.env" 2>&1)" "not found"
print "GH_TOKEN=x" >> "$env_file"
check "secrets refused" has "$(ccc-run-auto "$ident" "$env_file" 2>&1)" "GH_TOKEN"
print "HOME=/x" > "$env_file"
check "reserved variables refused" has "$(ccc-run-auto "$ident" "$env_file" 2>&1)" "can't be overridden"
print "FOO=1" > "$env_file"
check "missing API key refused" has "$(ccc-run-auto "$ident" "$env_file" 2>&1)" "must set ANTHROPIC_API_KEY"
check "gate required" has "$(CCC_EXPERIMENTAL_AUTO= ccc-run-auto "$ident" "$env_file" 2>&1)" experimental
check "malformed run id refused" has "$(ccc-auto-apply ../x 2>&1)" usage

check "nothing left behind at the end" no_leftovers
cd / && cleanup
print
(( fails )) && { print "$fails check(s) failed"; exit 1; }
print "all checks passed"
