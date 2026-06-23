# claude-code-capsule

Run Claude Code in disposable, identity-isolated Docker capsules. One volume, one identity.

Each identity gets its own named Docker volume holding its Claude login, so credentials never cross between them. Authenticate once per identity and it persists across runs.

## What's isolated (and what isn't)

Capsules isolate **identities**, not your machine. Each capsule:

- ✅ keeps each identity's Claude login in its own volume — credentials never cross
- ⚠️ mounts your **current directory** read-write at `/workspace` — Claude can read and edit everything under wherever you launched it, so launch from a specific project dir, **never from `~`**
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

Capsules default to `4g` of memory and `2` CPUs. Override those limits with environment variables:

```
CCC_MEMORY=8g CCC_CPUS=6 ccc-acme
```

For per-identity defaults, put them in your local wrapper:

```
ccc-acme() { CCC_MEMORY=8g CCC_CPUS=4 ccc-run acme "$@"; }
```

You can also pass extra Docker run args after the identity name or wrapper:

```
ccc-acme --memory=2g --cpus=2
```

## Notes

- **zsh only.** The wrapper-loading uses zsh syntax; source it from `~/.zshrc`, not bash.
- **Updates need a rebuild.** Containers run `--rm`, so any in-container auto-update is discarded. Run `ccc-build` to get a newer Claude Code — it rebuilds the image and clears the now-dangling old image and build cache so they don't accumulate. (Identity volumes are never touched.)
- **No git/SSH identity inside.** Capsules don't carry your git config or SSH keys, so commits and pushes from inside won't be authored or authenticated as you. Mount them yourself if you need to (e.g. add `-v ~/.gitconfig:/home/node/.gitconfig:ro`).
- **Light hardening only.** Capsules drop Linux capabilities, prevent new privileges, and cap process count, but the project directory is still mounted read-write.
