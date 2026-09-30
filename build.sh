#!/bin/bash
# Build only. Installing/relaunching is now an explicit, separate action.
set -euo pipefail
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$SRC_DIR/scripts/build-app.sh" "$@"
