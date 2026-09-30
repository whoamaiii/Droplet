#!/bin/bash
set -euo pipefail
SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SRC_DIR"
exec swift run --configuration debug DropletChecks
