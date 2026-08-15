#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

./scripts/build.sh
open -n .build/DerivedData/Build/Products/Debug/Rilliya.app
