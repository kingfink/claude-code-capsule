#!/bin/sh
# Image entrypoint. If ccc-run mounted a per-identity setup script
# (setup/<name>.sh in the repo), run it before the command.
if [ -f /ccc/setup.sh ]; then
  bash /ccc/setup.sh || echo "ccc: setup script failed (exit $?), continuing" >&2
fi
exec "$@"
