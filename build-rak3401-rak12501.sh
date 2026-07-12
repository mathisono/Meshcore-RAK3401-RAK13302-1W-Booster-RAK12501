#!/usr/bin/env bash
set -euo pipefail

# MeshCore upstream-patch builder for:
#   RAK WisMesh 1W Booster / RAK3401 + RAK13302 SX1262/SKY66122 PA + RAK12501 GNSS
#
# The source of truth is now the PR-style patch in patches/.
# This script clones MeshCore, applies that patch, then optionally builds all RAK3401 targets.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_FILE="${PATCH_FILE:-$REPO_ROOT/patches/0001-rak3401-rak12501-l76k-gps.patch}"
MESHCORE_UPSTREAM="${MESHCORE_UPSTREAM:-https://github.com/meshcore-dev/MeshCore.git}"
MESHCORE_BRANCH="${MESHCORE_BRANCH:-main}"
MESHCORE_DIR="${MESHCORE_DIR:-MeshCore}"
BUILD="${BUILD:-1}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

need_cmd git
need_cmd python3

if [[ ! -f "$PATCH_FILE" ]]; then
  echo "Patch file not found: $PATCH_FILE" >&2
  exit 1
fi

if [[ ! -d "$MESHCORE_DIR/.git" ]]; then
  echo "Cloning MeshCore into $MESHCORE_DIR ..."
  git clone --branch "$MESHCORE_BRANCH" "$MESHCORE_UPSTREAM" "$MESHCORE_DIR"
fi

cd "$MESHCORE_DIR"

echo "Using MeshCore checkout: $(pwd)"
echo "MeshCore HEAD: $(git rev-parse --short HEAD)"
echo "Patch: $PATCH_FILE"

if git apply --check "$PATCH_FILE"; then
  git apply "$PATCH_FILE"
  echo "Applied RAK3401 RAK12501/L76K GPS patch."
elif git apply --reverse --check "$PATCH_FILE"; then
  echo "Patch is already applied."
else
  echo "Patch does not apply cleanly to this MeshCore checkout." >&2
  echo "Try a fresh checkout or update the patch against the selected MeshCore branch." >&2
  exit 1
fi

if [[ "$BUILD" == "0" ]]; then
  echo "BUILD=0 set; patch complete, skipping PlatformIO build."
  exit 0
fi

if ! command -v pio >/dev/null 2>&1; then
  cat >&2 <<'EOF'
PlatformIO is not installed or pio is not on PATH.
Install it, then rerun:

  python3 -m venv ~/meshcore-build
  source ~/meshcore-build/bin/activate
  pip install -U platformio
  ./build-rak3401-rak12501.sh

EOF
  exit 1
fi

envs=(
  RAK_3401_repeater
  RAK_3401_room_server
  RAK_3401_companion_radio_usb
  RAK_3401_companion_radio_ble
  RAK_3401_terminal_chat
  RAK_3401_sensor
  RAK_3401_kiss_modem
)

for env in "${envs[@]}"; do
  echo "Building $env ..."
  pio run -e "$env"
done

cat <<'EOF'

Done.
Firmware outputs are under:
  .pio/build/RAK_3401_*/

Companion/app GPS custom vars:
  gps=1
  gps=0
  gps_interval=60
  gps_vehicle_mode=vehicle
EOF
