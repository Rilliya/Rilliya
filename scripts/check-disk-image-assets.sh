#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repository_root"

source_svg="assets/disk-image/RilliyaDiskImageBackground.svg"
rendered_png="assets/disk-image/RilliyaDiskImageBackground.png"
finder_layout="scripts/release/configure-disk-image.applescript"
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/rilliya-disk-image-check.XXXXXX")"
trap 'rm -rf "$temporary_directory"' EXIT

xmllint --noout "$source_svg"
osacompile -o "$temporary_directory/configure-disk-image.scpt" "$finder_layout"

width="$(sips -g pixelWidth "$rendered_png" | awk '/pixelWidth:/ { print $2 }')"
height="$(sips -g pixelHeight "$rendered_png" | awk '/pixelHeight:/ { print $2 }')"
dpi_width="$(sips -g dpiWidth "$rendered_png" | awk '/dpiWidth:/ { print $2 }')"
dpi_height="$(sips -g dpiHeight "$rendered_png" | awk '/dpiHeight:/ { print $2 }')"

if [[ "$width" != 1440 || "$height" != 880 ]]; then
  echo "$rendered_png must be exactly 1440 by 880 pixels" >&2
  exit 1
fi
if [[ "$dpi_width" != 144.000 || "$dpi_height" != 144.000 ]]; then
  echo "$rendered_png must declare a 144 DPI Retina representation" >&2
  exit 1
fi
