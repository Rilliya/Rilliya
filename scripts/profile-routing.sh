#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

pair_count="${1:-50}"
case "$pair_count" in
  ''|*[!0-9]*)
    echo "Node-pair count must be an integer from 1 through 2000." >&2
    exit 64
    ;;
esac
if [ "$pair_count" -lt 1 ] || [ "$pair_count" -gt 2000 ]; then
  echo "Node-pair count must be an integer from 1 through 2000." >&2
  exit 64
fi

architecture="$(uname -m)"
case "$architecture" in
  arm64|x86_64) ;;
  *)
    echo "Unsupported profiling architecture: $architecture" >&2
    exit 69
    ;;
esac

derived_data='.build/ProfileDerivedData'
output_directory='.build/Profiles'
mkdir -p "$output_directory"
run_id="$(date '+%Y%m%d-%H%M%S')"
run_prefix="$output_directory/routing-$pair_count-pairs-$run_id"
app_pid=''

{
  echo "git_sha=$(git rev-parse HEAD)"
  if [ -n "$(git status --porcelain)" ]; then
    echo "git_dirty=true"
  else
    echo "git_dirty=false"
  fi
  echo "pair_count=$pair_count"
  echo "architecture=$architecture"
  echo "os_version=$(sw_vers -productVersion)"
} >"$run_prefix.manifest.txt"

cleanup() {
  if [ -n "$app_pid" ] && kill -0 "$app_pid" 2>/dev/null; then
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT HUP INT TERM

./scripts/generate-project.sh
xcodebuild \
  -project Rilliya.xcodeproj \
  -scheme Rilliya \
  -configuration Release \
  -destination "platform=macOS,arch=$architecture" \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=PROFILE \
  build

binary="$derived_data/Build/Products/Release/Rilliya.app/Contents/MacOS/Rilliya"
dwarfdump --uuid "$binary" >>"$run_prefix.manifest.txt"
"$binary" \
  --routing-profile-node-pairs "$pair_count" \
  --routing-auto-pan \
  >"$run_prefix.log" 2>&1 &
app_pid=$!
sleep 4

ps -p "$app_pid" -o pid=,pcpu=,rss=,vsz=,etime=,command= \
  >"$run_prefix.process.txt"
footprint "$app_pid" >"$run_prefix.footprint.txt"
/usr/bin/sample "$app_pid" 5 1 -file "$run_prefix.sample.txt" >/dev/null

cat "$run_prefix.process.txt"
sed -n '1,20p' "$run_prefix.footprint.txt"
grep 'PROFILE_RENDERER' "$run_prefix.log" | tail -1 || true
echo "Manifest: $run_prefix.manifest.txt"
echo "Sample: $run_prefix.sample.txt"
echo "Footprint: $run_prefix.footprint.txt"

cleanup
app_pid=''
