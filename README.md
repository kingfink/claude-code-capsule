# claude-code-capsule

Run Claude Code in disposable, identity-isolated Docker capsules. One volume, one identity.

Each identity gets its own named Docker volume holding its Claude login, so credentials never cross between them. Authenticate once per identity and it persists across runs.

## What's isolated (and what isn't)

Capsules isolate **identities**, not your machine. Each capsule:

- ✅ keeps each identity's Claude login in its own volume — credentials never cross
- ⚠️ mounts your **current directory** read-write at `/<its basename>` inside the capsule (e.g. launching from `~/proj/folder_a` mounts it at `/folder_a`) — Claude can read and edit everything under wherever you launched it, so launch from a specific project dir, **never from `~`**
- ⚠️ has **unrestricted outbound network** (required for the API and MCP servers)

Treat a capsule as a clean identity, not a security sandbox.

## Setup

**1. Build the image** (once, and again whenever the Dockerfile changes):

```
docker build -t ccc .
```

After setup (step 2), rebuild with `ccc-build` instead — it builds and then prunes the leftover untagged image and stale build cache in one step, so rebuilds don't pile up.

**2. Load the commands into zsh.** Append this to `~/.zshrc`, using the real absolute path to where you cloned the repo:

```
echo 'source /Users/you/code/claude-code-capsule/bin/ccc-identities.sh' >> ~/.zshrc
```

Open a new terminal (or run that same `source` line by hand once) so the current shell picks it up.

**3. Add your identities.** Copy the example to a local file — it's gitignored, so your real names never get committed:

```
cp bin/ccc-identities.local.sh.example bin/ccc-identities.local.sh
```

Replace the placeholder wrappers in that copy with your own:

```
ccc-acme()  { ccc-run acme  "$@"; }
ccc-myself() { ccc-run myself "$@"; }
```

`ccc-identities.sh` sources this file automatically, so new wrappers are live in the next shell.

## Usage

```
cd ~/clients/acme && ccc-acme
```

First run, complete `/login` once; the volume keeps you authenticated after that. The generic form is `ccc-run <name>` if you don't want a wrapper.

Capsules default to `4g` of memory and `2` CPUs. Override those limits with environment variables — though they can't exceed what Docker Desktop allocates to its VM (Settings → Resources):

```
CCC_MEMORY=8g CCC_CPUS=2 ccc-acme
```

For per-identity defaults, put them in your local wrapper:

```
ccc-acme() { CCC_MEMORY=8g CCC_CPUS=2 ccc-run acme "$@"; }
```

You can also pass extra Docker run args after the identity name or wrapper:

```
ccc-acme --memory=2g --cpus=2
```

### Per-identity environment variables

`CCC_MEMORY` and `CCC_CPUS` configure the capsule from the *host* side. To set variables that Claude Code (and its MCP servers) see *inside* the capsule, give the identity its own env file and point the wrapper at it with `--env-file` — a native `docker run` flag that `ccc-run` forwards through. Keep the file outside the repo so secrets never get committed:

```
mkdir -p ~/.config/ccc && chmod 700 ~/.config/ccc
$EDITOR ~/.config/ccc/acme.env        # then: chmod 600 ~/.config/ccc/acme.env
```

```
# ~/.config/ccc/acme.env
SERVICE_BASE_URL=https://api.example.invalid
SERVICE_CLIENT_ID=...
SERVICE_CLIENT_SECRET=...
```

Wire it into the wrapper in your local `ccc-identities.local.sh`:

```
ccc-acme() { ccc-run acme --env-file "$HOME/.config/ccc/acme.env" "$@"; }
```

The env file is **plain `KEY=value` lines, not a shell script**: no `export`, no `$VAR` expansion, and quotes are taken literally (`FOO="bar"` sets the literal characters `"bar"`). A bare `KEY` with no `=` passes that variable's value through from your host shell at launch — handy for secrets you don't want written to the file. The named file must exist when you launch, or `docker run` errors out.

For a value common to *every* identity and not secret, add an `ENV` line to the `Dockerfile` and rebuild with `ccc-build` instead — but never put secrets there, since image layers are readable and shared across all identities.

### GitHub access

The image includes `gh`, and `git push` over HTTPS authenticates through it. Give an identity access by adding a token (ideally a fine-grained PAT limited to the repos it needs) and a commit identity to its env file:

```
# ~/.config/ccc/acme.env
GH_TOKEN=github_pat_...
GIT_AUTHOR_NAME=Your Name
GIT_AUTHOR_EMAIL=you@example.com
GIT_COMMITTER_NAME=Your Name
GIT_COMMITTER_EMAIL=you@example.com
```

### Per-identity tools

For client-specific CLIs, install them into the identity volume rather than the image. `~/.claude/bin` is on PATH and `XDG_CONFIG_HOME` points at `~/.claude/xdg-config`, both inside the volume, so a tool and its config persist for that identity only.

To install automatically, give the identity a setup script. It's gitignored like your wrappers:

```
cp setup/example.sh.example setup/acme.sh
```

`ccc-run` mounts `setup/<name>.sh` and the capsule runs it at every launch, before Claude starts, so keep it idempotent (the example only installs what's missing). Keep secrets in the env file, not here.

To upgrade, delete the binary (`ccc-acme -- rm ~/.claude/bin/omni`) and the next launch reinstalls it. Tools that honor `XDG_CONFIG_HOME` (Omni does) keep their config in the volume too. Note the volume is writable from inside the capsule, so Claude can modify these tools.

### Running a shell or one-off command

Capsules launch `claude` by default. Anything after `--` replaces that command — same identity volume, same read-write mount of your launch directory, running as the non-root `node` user:

```
ccc-acme -- bash                      # interactive shell
ccc-acme -- omni whoami               # one command, then exit
ccc-acme -- bash -c 'which omni && gh auth status'
```

Docker flags still go before the `--`, e.g. `ccc-acme --memory=8g -- bash`.

### Auto mode

`ccc-run-auto` runs Claude in [auto mode](https://code.claude.com/docs/en/permission-modes) on a throwaway clone of the current repo, with a throwaway copy of the identity, on a network where it can reach only the Anthropic API. When Claude exits, you get the changes as a patch and are asked whether to apply it. Rebuild the image with `ccc-build` first.

It takes an env file that must set `ANTHROPIC_API_KEY`; the identity's OAuth login is not used, and secret-looking variables are refused. Run it from a clean checkout:

```
ccc-acme-auto() { ccc-run-auto acme-auto "$HOME/.config/ccc/acme-auto.env" "$@"; }

ccc-acme-auto                                            # auto mode
ccc-acme-auto -- claude --dangerously-skip-permissions   # no permission checks at all
```

If you decline the patch, or the export fails, `ccc-auto-apply <run-id>` picks it up later. Nothing is ever committed for you. Gitignored files and submodules aren't carried into the clone, LFS files arrive as pointers, and Claude's commits arrive as one patch. Applying runs the patch through your git setup like any incoming change, so read it first if the repo uses custom filters. `CCC_MEMORY` and `CCC_CPUS` apply as for `ccc-run`. After a crash, remove leftovers with:

```
docker rm -f $(docker ps -aq --filter label=ccc.auto=1)
docker network rm $(docker network ls -q --filter label=ccc.auto=1)
docker volume rm $(docker volume ls -q --filter label=ccc.auto=1)
```

**Network.** Claude's container sits on an internal Docker network with no route out and no outside DNS. Its only way out is a proxy container that holds the API key: Claude calls the API through it with a placeholder token and the proxy adds the real key, so the key never enters Claude's container. The proxy forwards only message and token-counting requests, and refuses the API features that fetch a URL on the caller's behalf (the MCP connector, the web fetch tool, images and documents given by URL). Web search still works. Everything else is blocked: WebFetch, remote MCP servers, package registries, and downloads in the identity's setup script. After each run, `ccc-run-auto` lists the hosts it blocked, and the run's `proxy.log` has every decision. Claude Code's own startup checks (`downloads.claude.ai`, `github.com`) always show up there and are harmless.

To let Claude reach more hosts over HTTPS, list them in `CCC_AUTO_ALLOW_HOSTS`, as exact names or `*.suffix`, separated by spaces or commas. For example, to install npm dependencies:

```
ccc-acme-auto() { CCC_AUTO_ALLOW_HOSTS=registry.npmjs.org ccc-run-auto acme-auto "$HOME/.config/ccc/acme-auto.env" "$@"; }
```

Every host you allow is a way out: a prompt-injected run could publish your code to npm with a token planted in the injection, or push it to someone else's GitHub repo. Allow only what the task needs. Also keep in mind that whatever Claude sends the model goes to Anthropic under your key, and that a future API feature that fetches URLs server-side won't be blocked until the proxy knows about it.

## Notes

- **zsh only.** The wrapper-loading uses zsh syntax; source it from `~/.zshrc`, not bash.
- **Updates need a rebuild.** Containers run `--rm`, so any in-container auto-update is discarded. Run `ccc-build` to get a newer Claude Code — it rebuilds the image and clears the now-dangling old image and build cache so they don't accumulate. (Identity volumes are never touched.)
- **No git/SSH identity by default.** Capsules don't carry your git config or SSH keys. For HTTPS pushes and commit authorship, set it per identity as in [GitHub access](#github-access).
- **Light hardening only.** Capsules drop Linux capabilities, prevent new privileges, and cap process count, but the project directory is still mounted read-write.

