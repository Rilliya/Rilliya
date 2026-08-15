#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

xcrun swift-format format \
  --configuration .swift-format \
  --in-place \
  --parallel \
  --recursive \
  Sources \
  Tests
