# Auto mode (experimental)

`ccc-run-auto` runs `claude --dangerously-skip-permissions` so that a run can't leave anything behind: not in your checkout, not in your identity, not on your machine. Claude works on a throwaway clone of your repo with a throwaway copy of the identity. The only thing that comes back is a patch, which you review and apply yourself.

**Not finished.** Outbound network is still unrestricted, so a prompt-injected run can send the API key and your source code anywhere. An egress-allowlisting proxy is planned. Until then, `ccc-run-auto` refuses to start unless `CCC_EXPERIMENTAL_AUTO=1` is set.

## Usage

Give each identity a separate `-auto` variant and an env file that holds only an API key (ideally one with a spend limit):

```
# ~/.config/ccc/acme-auto.env
ANTHROPIC_API_KEY=sk-ant-...
```

```
ccc-acme-auto() { CCC_EXPERIMENTAL_AUTO=1 ccc-run-auto acme-auto --env-file "$HOME/.config/ccc/acme-auto.env" "$@"; }
```

Then, from a clean checkout:

```
cd ~/clients/acme/app
ccc-acme-auto            # Claude asks you to accept skip-permissions each run
ccc-auto-apply           # review the report and patch, then apply
git diff                 # nothing is committed for you
```

Only `--memory`, `--cpus`, `--env-file` and `-e/--env` are accepted before `--`. Anything after `--` replaces the `claude --dangerously-skip-permissions` command, as with `ccc-run`.

## What a run does

1. **Checks the checkout.** It must be a git repo with no uncommitted or untracked changes. Submodules aren't supported. Git LFS files arrive as pointer files. Gitignored files (`.env`, `node_modules`, build output) aren't in the clone, so Claude has to reinstall dependencies itself.
2. **Clones HEAD into a Docker volume** from a `git bundle`. Claude's files never touch your disk, and your checkout's `.git` (hooks, config) is never mounted.
3. **Copies the identity volume** `ccc-<name>-config` into a throwaway volume, and deletes `.credentials.json` from the copy when an API key is given. Anything Claude plants there (a trojan in `~/.claude/bin`, hooks in `settings.json`) is thrown away with the copy. It refuses to copy an identity volume a running container is using, since the copy could be inconsistent (override: `CCC_AUTO_ALLOW_LIVE_COPY=1`).
4. **Runs the agent** with the same restrictions as `ccc-run`: all capabilities dropped, no new privileges, pid/memory/CPU limits, non-root. The per-identity setup script still runs.
5. **Exports a patch** in a separate container with no network. It diffs Claude's files against the starting commit using a fresh `.git` built from the bundle, so nothing Claude did to the clone's `.git` (config, hooks, rewritten history) is read or trusted. Committed and uncommitted work look the same in the patch. New files that the final `.gitignore` ignores are left out.
6. **Cleans up** the containers and volumes, also after Ctrl-C.

Each run's files live in `~/.local/share/ccc/auto-runs/<run-id>/`:
- `changes.patch`: the patch
- `report.txt`: flags paths that need a close look (CI config, `.claude/`, env files, build scripts, dependency manifests, Docker files, binaries, executables, symlinks)
- `meta`: the repo, starting commit and exit status

## Credentials and secrets

- An API key is expected. To use the identity's OAuth login instead, set `CCC_AUTO_ALLOW_OAUTH=1`. This is untested: if Claude refreshes the token inside the copy, the original identity may be logged out.
- Env keys that look like secrets (`*TOKEN*`, `*SECRET*`, `*PASSWORD*`, `*_KEY`, ...) are refused unless `CCC_AUTO_ALLOW_SECRETS=1`. Only key names are ever printed. Don't give an auto capsule `GH_TOKEN`: push from the host after applying.
- `HOME`, `PATH`, `CLAUDE_CONFIG_DIR`, `XDG_CONFIG_HOME`, `ANTHROPIC_BASE_URL` and the proxy variables are reserved and can't be set.

## Applying

`ccc-auto-apply [run-id]` picks the latest run for the current repo. Before applying anything it requires:
- a clean checkout
- HEAD at the run's starting commit
- git 2.39.2 or newer, for `git apply`'s symlink protections
- a passing `git apply --check`

It shows the report and `git apply --stat`, and applies only when you confirm. It never commits, runs, tests or pushes anything. Treat the whole patch as untrusted, especially the flagged files.

## When something goes wrong

- If the export fails, the run's scratch volume is kept. Retry with `ccc-auto-export <run-id>`.
- `ccc-auto-gc` removes auto-mode containers and volumes left behind. It asks before deleting scratch volumes that were never exported. It only touches resources labeled `ccc.auto`, never `ccc-<name>-config`.
