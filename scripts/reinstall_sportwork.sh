#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

cd "$ROOT_DIR"

./scripts/clean_sportwork.sh
./build.sh

cp -R "$ROOT_DIR/build/SportWork.app" /Applications/SportWork.app
open /Applications/SportWork.app

echo
echo "Reinstalled and launched:"
echo "/Applications/SportWork.app"
