#!/bin/zsh
# Build all products. Usage: Tools/build.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c "${1:-debug}"
