FROM node:22

# Install Claude Code globally. This is a root-owned npm global install, and the
# container runs as the non-root "node" user, so Claude can't self-update at
# runtime ("npm global folder isn't writable") — rebuild the image to upgrade.
# Pin a version (@anthropic-ai/claude-code@X.Y.Z) for fully reproducible builds.
RUN npm install -g @anthropic-ai/claude-code

# node:22 ships a non-root "node" user. Create its config dir, chown it, and run
# as node so Claude never runs as root.
RUN mkdir -p /home/node/.claude && chown -R node:node /home/node/.claude
USER node

ENV CLAUDE_CONFIG_DIR=/home/node/.claude
WORKDIR /workspace

CMD ["claude"]
