# claude-code-capsule

Run Claude Code in Docker with one volume per identity, so logins never mix.

**Not a sandbox.** A capsule mounts the directory you launch it from read-write and has unrestricted network access. Launch it from a project directory, never from `~`.

## Setup

```
docker build -t ccc .
echo 'source /path/to/claude-code-capsule/bin/ccc-identities.sh' >> ~/.zshrc
cp bin/ccc-identities.local.sh.example bin/ccc-identities.local.sh
```

Add a wrapper per identity to `bin/ccc-identities.local.sh` (gitignored), then open a new zsh:

```
ccc-acme() { ccc-run acme --env-file "$HOME/.config/ccc/acme.env" "$@"; }
```

## Usage

```
cd ~/clients/acme && ccc-acme        # run Claude (/login once per identity)
ccc-acme -- bash                     # run something else instead
ccc-acme --memory=8g                 # docker run flags go before --
CCC_MEMORY=8g CCC_CPUS=4 ccc-acme    # defaults: 4g, 2 CPUs
ccc-build                            # rebuild (e.g. for a newer Claude Code) and prune old images
```

- **Env file:** plain `KEY=value` lines (quotes are literal, no `export` or `$VAR`). A bare `KEY` passes the host's value through. For `gh` and HTTPS pushes, set `GH_TOKEN` and `GIT_AUTHOR_*`/`GIT_COMMITTER_*` there.
- **Tools:** `~/.claude/bin` (on `PATH`) and `XDG_CONFIG_HOME` live in the identity volume. `setup/<name>.sh` (gitignored; start from `setup/example.sh.example`) runs at every launch, so keep it idempotent.

## Auto mode (experimental)

`ccc-run-auto` runs Claude in [auto mode](https://code.claude.com/docs/en/permission-modes) on a throwaway clone of the current repo and a throwaway copy of the identity, then hands the changes back as a patch for you to review and apply. It can reach only the Anthropic API, through a proxy that holds the API key. Rebuild with `ccc-build` if your image predates it.

```
ccc-acme-auto() { ccc-run-auto acme-auto "$HOME/.config/ccc/acme-auto.env" "$@"; }

ccc-acme-auto                                            # auto mode
ccc-acme-auto -- claude --dangerously-skip-permissions   # no permission checks
```

- Run it from a clean checkout. The env file must set `ANTHROPIC_API_KEY` (ideally one with a spend limit) and can't hold other secrets.
- Nothing is committed for you. `ccc-auto-apply <run-id>` applies a patch you declined.
- Gitignored files like `node_modules` aren't in the clone. To let Claude reinstall them, allow the registry: `CCC_AUTO_ALLOW_HOSTS=registry.npmjs.org` (space-separated, `*.suffix` works). Every allowed host is a way for a prompt-injected run to send your code out.
- Blocked hosts are listed after each run. Details are in `~/.local/share/ccc/auto-runs/<run-id>/proxy.log`.
- After a crash, remove containers, networks and volumes labeled `ccc.auto=1`.
