FROM node:22

# Install Claude Code globally. This is a root-owned npm global install, and the
# container runs as the non-root "node" user, so Claude can't self-update at
# runtime ("npm global folder isn't writable") — rebuild the image to upgrade.
# Pin a version (@anthropic-ai/claude-code@X.Y.Z) for fully reproducible builds.
RUN npm install -g @anthropic-ai/claude-code

# GitHub CLI, with git using it for HTTPS auth (reads GH_TOKEN from the env).
RUN apt-get update && apt-get install -y --no-install-recommends gh \
  && rm -rf /var/lib/apt/lists/* \
  && git config --system credential.helper '!gh auth git-credential'

# node:22 ships a non-root "node" user. Create its config dir, chown it, and run
# as node so Claude never runs as root.
RUN mkdir -p /home/node/.claude && chown -R node:node /home/node/.claude
COPY --chmod=755 bin/ccc-entrypoint.sh /usr/local/bin/ccc-entrypoint
USER node

ENV CLAUDE_CONFIG_DIR=/home/node/.claude

# Per-identity tools and their config live in the identity volume so they
# survive --rm restarts without baking client-specific tools into the image.
ENV PATH=/home/node/.claude/bin:$PATH \
    XDG_CONFIG_HOME=/home/node/.claude/xdg-config

# The launch directory is bind-mounted at /<its basename> and ccc-run sets the
# working dir to match at runtime (docker run -w), so no WORKDIR is set here.

ENTRYPOINT ["ccc-entrypoint"]
CMD ["claude"]
