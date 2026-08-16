#!/bin/bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <application> <output-dmg>" >&2
  exit 64
fi

application=$1
output=$2
script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/../.." && pwd)"
background="$repository_root/assets/disk-image/RilliyaDiskImageBackground.png"
application_icon="$application/Contents/Resources/AppIcon.icns"
temporary_root=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
workspace="$(mktemp -d "$temporary_root/rilliya-dmg.XXXXXX")"
staging="$workspace/Rilliya"
editable_image="$workspace/Rilliya.sparsebundle"
mount_point="$workspace/mount"
image_device=
is_mounted=false
mkdir -p "$staging"

cleanup() {
  if [[ "$is_mounted" == true && -n "$image_device" ]]; then
    diskutil eject "$image_device" >/dev/null 2>&1 || true
  fi
  rm -rf "$workspace"
}
trap cleanup EXIT

if [[ ! -d "$application" ]]; then
  echo "Application does not exist: $application" >&2
  exit 66
fi
if [[ ! -f "$application_icon" ]]; then
  echo "Application icon does not exist: $application_icon" >&2
  exit 66
fi
if [[ ! -f "$background" ]]; then
  echo "Disk image background does not exist: $background" >&2
  exit 66
fi

mkdir -p "$(dirname "$output")"
ditto "$application" "$staging/Rilliya.app"
ln -s /Applications "$staging/Applications"
mkdir -p "$staging/.background"
ditto "$background" "$staging/.background/RilliyaDiskImageBackground.png"
ditto "$application_icon" "$staging/.VolumeIcon.icns"
SetFile -c icnC "$staging/.VolumeIcon.icns"
SetFile -a V "$staging/.background" "$staging/.VolumeIcon.icns"
SetFile -a C "$staging"

if [[ -e "$output" ]]; then
  rm "$output"
fi

diskutil image create from \
  --format UDSB \
  "$staging" \
  "$editable_image"

mkdir -p "$mount_point"
attach_output="$(
  diskutil image attach \
    --nobrowse \
    --mountPoint "$mount_point" \
    "$editable_image"
)"
image_device="$(
  printf '%s\n' "$attach_output" |
    awk '/^\/dev\// { print $1; exit }'
)"
if [[ -z "$image_device" ]]; then
  echo "Could not determine the attached disk image device." >&2
  exit 1
fi
is_mounted=true

SetFile -a V "$mount_point/.background" "$mount_point/.VolumeIcon.icns"
SetFile -c icnC "$mount_point/.VolumeIcon.icns"
SetFile -a C "$mount_point"
osascript "$script_directory/configure-disk-image.applescript" "$mount_point"
ditto "$application_icon" "$mount_point/.VolumeIcon.icns"
SetFile -a V "$mount_point/.background" "$mount_point/.VolumeIcon.icns"
SetFile -c icnC "$mount_point/.VolumeIcon.icns"
SetFile -a C "$mount_point"
sync
diskutil eject "$image_device"
is_mounted=false

hdiutil convert \
  "$editable_image" \
  -format ULMO \
  -o "$output"

attach_output="$(
  diskutil image attach \
    --readOnly \
    --nobrowse \
    --mountPoint "$mount_point" \
    "$output"
)"
image_device="$(
  printf '%s\n' "$attach_output" |
    awk '/^\/dev\// { print $1; exit }'
)"
if [[ -z "$image_device" ]]; then
  echo "Could not determine the final disk image device." >&2
  exit 1
fi
is_mounted=true

test -f "$mount_point/.DS_Store"
test -f "$mount_point/.VolumeIcon.icns"
test -f "$mount_point/.background/RilliyaDiskImageBackground.png"
root_attributes="$(GetFileInfo -a "$mount_point")"
if [[ "$root_attributes" != *C* ]]; then
  echo "The final disk image is missing its custom volume icon attribute." >&2
  exit 1
fi

diskutil eject "$image_device"
is_mounted=false
