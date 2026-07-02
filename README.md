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

### Getting a shell inside the capsule

Capsules launch `claude` by default. To open a plain shell instead — same identity volume, same read-write mount of your launch directory, running as the non-root `node` user — override the entrypoint:

```
ccc-acme --entrypoint bash
```

This works because `--entrypoint` is a flag that lands before the image name, which is where `ccc-run` forwards extra args (appending a bare `bash` after the wrapper would *not* work — the passthrough sits before the image, so an override command wouldn't reach the right position). Use `sh` if you prefer.

If you do this often, add a helper to your local `ccc-identities.local.sh`:

```
ccc-shell() { ccc-run "$1" --entrypoint bash "${@:2}"; }
```

Then `ccc-shell acme` opens a shell for any identity.

## Notes

- **zsh only.** The wrapper-loading uses zsh syntax; source it from `~/.zshrc`, not bash.
- **Updates need a rebuild.** Containers run `--rm`, so any in-container auto-update is discarded. Run `ccc-build` to get a newer Claude Code — it rebuilds the image and clears the now-dangling old image and build cache so they don't accumulate. (Identity volumes are never touched.)
- **No git/SSH identity inside.** Capsules don't carry your git config or SSH keys, so commits and pushes from inside won't be authored or authenticated as you. Mount them yourself if you need to (e.g. add `-v ~/.gitconfig:/home/node/.gitconfig:ro`).
- **Light hardening only.** Capsules drop Linux capabilities, prevent new privileges, and cap process count, but the project directory is still mounted read-write.

