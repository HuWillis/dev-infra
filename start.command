#!/bin/sh
set -eu
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.docker/bin:$HOME/.rd/bin:$PATH"
cd "$(dirname "$0")"
exec python3 start.py "$@"
