#!/usr/bin/env bash
set -euo pipefail

# MeshCore custom firmware builder for:
#   RAK WisMesh 1W Booster / RAK3401 + RAK13302 SX1262/SKY66122 PA + RAK12501 GNSS
#
# What this does:
#   1. Clones MeshCore if needed.
#   2. Patches the RAK3401 variant so the RAK12501 UART GPS is enabled for all RAK_3401_* builds.
#   3. Forces the simple UART GPS path instead of the WisBlock RAK12500 I2C/GPIO probe path.
#   4. Builds every RAK3401 firmware environment by default.
#
# Usage:
#   chmod +x build-rak3401-rak12501.sh
#   ./build-rak3401-rak12501.sh
#
# Optional:
#   MESHCORE_DIR=~/MeshCore BUILD=0 ./build-rak3401-rak12501.sh   # patch only
#   MESHCORE_BRANCH=main ./build-rak3401-rak12501.sh
#
# Notes:
#   - RAK12501 is a UART GNSS module. It should be mounted in WisBlock Slot A or Slot D.
#   - Do not power-save/toggle WB_IO2/PIN_3V3_EN on the RAK3401 1W Booster. That rail also keeps
#     the RAK13302 5V boost regulator alive for the SKY66122 PA.
#   - MeshCore currently spells PERSISTANT_GPS that way; keep the spelling.

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

if [[ ! -d "$MESHCORE_DIR/.git" ]]; then
  echo "Cloning MeshCore into $MESHCORE_DIR ..."
  git clone --branch "$MESHCORE_BRANCH" "$MESHCORE_UPSTREAM" "$MESHCORE_DIR"
fi

cd "$MESHCORE_DIR"

echo "Using MeshCore checkout: $(pwd)"
echo "MeshCore HEAD: $(git rev-parse --short HEAD)"

python3 - <<'PY'
from pathlib import Path

variant_h = Path("variants/rak3401/variant.h")
platformio_ini = Path("variants/rak3401/platformio.ini")
env_mgr_cpp = Path("src/helpers/sensors/EnvironmentSensorManager.cpp")

for path in (variant_h, platformio_ini, env_mgr_cpp):
    if not path.exists():
        raise SystemExit(f"Required file missing: {path}")

# -----------------------------------------------------------------------------
# 1) RAK3401 + RAK12501 UART GPS pin mapping
# -----------------------------------------------------------------------------
text = variant_h.read_text()
old_gps_block = """// RAK1910 GPS module
// If using the wisblock GPS module and pluged into Port A on WisBlock base
// IO1 is hooked to PPS (pin 12 on header) = gpio 17
// IO2 is hooked to GPS RESET = gpio 34, but it can not be used to this because IO2 is ALSO used to control 3V3_S power (1 is on).
// Therefore must be 1 to keep peripherals powered
// Power is on the controllable 3V3_S rail
#define PIN_GPS_PPS (17) // Pulse per second input from the GPS

#define PIN_GPS_RX PIN_SERIAL1_RX
#define PIN_GPS_TX PIN_SERIAL1_TX

#define PIN_GPS_1PPS PIN_GPS_PPS
#define GPS_BAUD_RATE 9600
#define GPS_ADDRESS 0x42  //i2c address for GPS
"""
new_gps_block = """// RAK12501 UART GNSS module
// RAK12501 works from WisBlock Slot A or Slot D and speaks NMEA over UART.
// MeshCore calls Serial1.setPins(PIN_GPS_TX, PIN_GPS_RX); this matches the
// working RAK4631 convention where GPS TXD feeds MCU RX and GPS RXD feeds MCU TX.
//
// IMPORTANT for RAK3401 + RAK13302 1W Booster:
// WB_IO2 / PIN_3V3_EN also controls the RAK13302 5V boost rail for the SKY66122 PA.
// Keep that rail HIGH during operation; do not use it as a GPS sleep/reset pin.
#define PIN_GPS_PPS (17) // Pulse per second input from the GPS
#define PIN_GPS_TX PIN_SERIAL1_RX
#define PIN_GPS_RX PIN_SERIAL1_TX
#define PIN_GPS_1PPS PIN_GPS_PPS
#define PIN_GPS_EN -1
#define GPS_BAUD_RATE 9600
#define GPS_ADDRESS 0x42  // kept for compatibility; RAK12501 uses UART NMEA here
"""

if new_gps_block not in text:
    if old_gps_block not in text:
        raise SystemExit("Could not find the expected RAK3401 GPS block in variant.h; upstream changed")
    text = text.replace(old_gps_block, new_gps_block)
    variant_h.write_text(text)
    print(f"patched {variant_h}")
else:
    print(f"already patched {variant_h}")

# -----------------------------------------------------------------------------
# 2) RAK3401 base build flags inherited by every RAK_3401_* environment
# -----------------------------------------------------------------------------
text = platformio_ini.read_text()
flags = [
    "  -D RAK12501_UART_GPS=1",
    "  -D ENV_SKIP_GPS_DETECT=1",
    "  -D PERSISTANT_GPS=1",
]
anchor = "  -D SX126X_REGISTER_PATCH=1       ; Patch register 0x8B5 for improved RX with SKY66122 FEM\n"
if not all(flag in text for flag in flags):
    if anchor not in text:
        raise SystemExit("Could not find RAK3401 build flag anchor in platformio.ini; upstream changed")
    add = "".join(flag + "\n" for flag in flags if flag not in text)
    text = text.replace(anchor, anchor + add)
    platformio_ini.write_text(text)
    print(f"patched {platformio_ini}")
else:
    print(f"already patched {platformio_ini}")

# -----------------------------------------------------------------------------
# 3) Force RAK12501 to use basic serial GPS, not RAK12500 WisBlock I2C/GPIO scan
# -----------------------------------------------------------------------------
text = env_mgr_cpp.read_text()
old_guard = """#if ENV_INCLUDE_GPS && defined(RAK_BOARD) && !defined(RAK_WISMESH_TAG)
#define RAK_WISBLOCK_GPS
#endif
"""
new_guard = """#if ENV_INCLUDE_GPS && defined(RAK_BOARD) && !defined(RAK_WISMESH_TAG) && !defined(RAK12501_UART_GPS)
#define RAK_WISBLOCK_GPS
#endif
"""
if new_guard not in text:
    if old_guard not in text:
        raise SystemExit("Could not find RAK_WISBLOCK_GPS guard in EnvironmentSensorManager.cpp; upstream changed")
    text = text.replace(old_guard, new_guard)
    env_mgr_cpp.write_text(text)
    print(f"patched {env_mgr_cpp}")
else:
    print(f"already patched {env_mgr_cpp}")

print("RAK3401 + RAK12501 GPS patch complete")
PY

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

Flash the BLE companion first for bring-up:
  .pio/build/RAK_3401_companion_radio_ble/firmware.uf2

Then check serial logs at 115200 baud and verify that GPS appears in the MeshCore app.
EOF
