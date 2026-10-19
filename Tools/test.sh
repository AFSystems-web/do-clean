#!/bin/zsh
# Run the whole test suite.
set -euo pipefail
cd "$(dirname "$0")/.."
swift test "$@"
