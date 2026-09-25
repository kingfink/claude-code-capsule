#!/bin/sh
# Image entrypoint. If ccc-run mounted a per-identity setup script
# (~/.config/ccc/<name>.setup.sh on the host), run it before the command.
if [ -f /ccc/setup.sh ]; then
  bash /ccc/setup.sh || echo "ccc: setup script failed (exit $?), continuing" >&2
fi
exec "$@"
