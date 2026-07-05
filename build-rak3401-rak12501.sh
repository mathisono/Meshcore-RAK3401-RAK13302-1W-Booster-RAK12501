#!/usr/bin/env bash
set -euo pipefail

# MeshCore custom firmware builder for:
#   RAK WisMesh 1W Booster / RAK3401 + RAK13302 SX1262/SKY66122 PA + RAK12501 GNSS
#
# This patch keeps the RAK3401/Rak13302 1W radio support from MeshCore, but replaces
# the generic WisBlock GPS detection path with a RAK12501 / Quectel L76K UART GPS init
# patterned after Meshtastic's verified RAK3401 1W behavior:
#
#   $PCAS04,7*1E                                  GPS + GLONASS + BeiDou
#   $PCAS03,1,0,0,0,1,0,0,0,0,0,,,0,0*02          RMC + GGA only
#   $PCAS11,3*1E                                  vehicle mode
#
# The MeshCore app still controls GPS through the normal "gps" custom setting:
#   gps=1  -> start GPS, run the L76K config, and publish live location
#   gps=0  -> stop GPS
#
# It also exposes:
#   gps_interval       seconds between GPS telemetry updates
#   gps_vehicle_mode   L76K PCAS11 mode; "vehicle" maps to 3, numeric 0..7 accepted
#
# Usage:
#   chmod +x build-rak3401-rak12501.sh
#   ./build-rak3401-rak12501.sh
#
# Optional:
#   MESHCORE_DIR=~/MeshCore BUILD=0 ./build-rak3401-rak12501.sh   # patch only
#   MESHCORE_BRANCH=main ./build-rak3401-rak12501.sh

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

def replace_between(text: str, start_marker: str, end_marker: str, replacement: str) -> str:
    start = text.find(start_marker)
    if start < 0:
        raise SystemExit(f"Could not find start marker: {start_marker!r}")
    end = text.find(end_marker, start)
    if end < 0:
        raise SystemExit(f"Could not find end marker after {start_marker!r}: {end_marker!r}")
    end += len(end_marker)
    return text[:start] + replacement + text[end:]

def replace_function(text: str, signature: str, next_signature: str, replacement: str) -> str:
    start = text.find(signature)
    if start < 0:
        raise SystemExit(f"Could not find function signature: {signature}")
    end = text.find(next_signature, start + len(signature))
    if end < 0:
        raise SystemExit(f"Could not find next function marker after {signature}: {next_signature}")
    return text[:start] + replacement + text[end:]

# -----------------------------------------------------------------------------
# 1) RAK3401 + RAK12501 UART GPS pin mapping
# -----------------------------------------------------------------------------
text = variant_h.read_text()
gps_start_markers = [
    "// RAK12501 UART GNSS module",
    "// RAK1910 GPS module",
]
gps_start = next((m for m in gps_start_markers if m in text), None)
if gps_start is None:
    raise SystemExit("Could not find RAK3401 GPS block in variant.h; upstream changed")

# End at the compatibility GPS_ADDRESS define in either the old or previously patched block.
gps_end = "#define GPS_ADDRESS 0x42  // kept for compatibility; RAK12501 uses UART NMEA here\n"
if gps_end not in text[text.find(gps_start):]:
    gps_end = "#define GPS_ADDRESS 0x42  // kept for compatibility; RAK12501/L76K uses UART NMEA here\n"
if gps_end not in text[text.find(gps_start):]:
    gps_end = "#define GPS_ADDRESS 0x42  //i2c address for GPS\n"

new_gps_block = """// RAK12501 UART GNSS module
// RAK12501 uses the Quectel L76K and speaks NMEA over UART.
// Slot A/D UART mapping matches Meshtastic's RAK3401 1W variant:
//   MCU RX = P0.15, MCU TX = P0.16
//
// MeshCore's current GPS helper calls Serial1.setPins(PIN_GPS_TX, PIN_GPS_RX).
// Keep these definitions aligned with the existing MeshCore RAK4631 convention so
// that call expands to setPins(MCU_RX, MCU_TX).
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
#define GPS_ADDRESS 0x42  // kept for compatibility; RAK12501/L76K uses UART NMEA here
"""
text = replace_between(text, gps_start, gps_end, new_gps_block)
variant_h.write_text(text)
print(f"patched {variant_h}")

# -----------------------------------------------------------------------------
# 2) RAK3401 base build flags inherited by every RAK_3401_* environment
# -----------------------------------------------------------------------------
text = platformio_ini.read_text()
for stale_flag in (
    "  -D RAK12501_UART_GPS=1\n",
    "  -D ENV_SKIP_GPS_DETECT=1\n",
    "  -D PERSISTANT_GPS=1\n",
):
    text = text.replace(stale_flag, "")

new_flags = [
    "  -D RAK12501_L76K_GPS=1",
    "  -D RAK12501_L76K_NAV_MODE=3      ; Meshtastic-style vehicle mode: $PCAS11,3",
    "  -D RAK12501_GPS_DEFAULT_ENABLE=0 ; app controls GPS via custom setting gps=1/gps=0",
]
for flag in new_flags:
    text = text.replace(flag + "\n", "")

anchor = "  -D SX126X_REGISTER_PATCH=1       ; Patch register 0x8B5 for improved RX with SKY66122 FEM\n"
if anchor not in text:
    raise SystemExit("Could not find RAK3401 build flag anchor in platformio.ini; upstream changed")
text = text.replace(anchor, anchor + "".join(flag + "\n" for flag in new_flags))
platformio_ini.write_text(text)
print(f"patched {platformio_ini}")

# -----------------------------------------------------------------------------
# 3) Make RAK12501/L76K use UART GPS instead of the RAK12500 WisBlock I2C/GPIO scan
# -----------------------------------------------------------------------------
text = env_mgr_cpp.read_text()
text = text.replace(
    "#if ENV_INCLUDE_GPS && defined(RAK_BOARD) && !defined(RAK_WISMESH_TAG) && !defined(RAK12501_UART_GPS)\n#define RAK_WISBLOCK_GPS\n#endif\n",
    "#if ENV_INCLUDE_GPS && defined(RAK_BOARD) && !defined(RAK_WISMESH_TAG) && !defined(RAK12501_L76K_GPS)\n#define RAK_WISBLOCK_GPS\n#endif\n",
)
text = text.replace(
    "#if ENV_INCLUDE_GPS && defined(RAK_BOARD) && !defined(RAK_WISMESH_TAG)\n#define RAK_WISBLOCK_GPS\n#endif\n",
    "#if ENV_INCLUDE_GPS && defined(RAK_BOARD) && !defined(RAK_WISMESH_TAG) && !defined(RAK12501_L76K_GPS)\n#define RAK_WISBLOCK_GPS\n#endif\n",
)

# Insert RAK12501/L76K helpers once, right after the RAK12500 provider block.
helper_marker = "// RAK12501/L76K GPS helpers"
helper_block = r'''
// RAK12501/L76K GPS helpers
#if ENV_INCLUDE_GPS && defined(RAK12501_L76K_GPS)
#ifndef RAK12501_L76K_NAV_MODE
#define RAK12501_L76K_NAV_MODE 3
#endif

#ifndef RAK12501_GPS_DEFAULT_ENABLE
#define RAK12501_GPS_DEFAULT_ENABLE 0
#endif

#ifndef RAK12501_L76K_BOOT_DELAY_MS
#define RAK12501_L76K_BOOT_DELAY_MS 1000
#endif

static uint8_t rak12501_l76k_nav_mode =
  (RAK12501_L76K_NAV_MODE <= 7) ? RAK12501_L76K_NAV_MODE : 3;

static void rak12501SendNMEA(Stream& serial, const char* body) {
  uint8_t checksum = 0;
  for (const char* p = body; *p; ++p) {
    checksum ^= (uint8_t)*p;
  }

  serial.print('$');
  serial.print(body);
  serial.print('*');
  if (checksum < 0x10) {
    serial.print('0');
  }
  serial.print(checksum, HEX);
  serial.print("\r\n");
}

static void rak12501ApplyL76KNavMode() {
  if (rak12501_l76k_nav_mode > 7) {
    rak12501_l76k_nav_mode = 3;
  }

  char body[16];
  snprintf(body, sizeof(body), "PCAS11,%u", rak12501_l76k_nav_mode);
  rak12501SendNMEA(Serial1, body);
}

static int rak12501ParseL76KNavMode(const char* value) {
  if (value == nullptr || *value == '\0') {
    return -1;
  }

  // Verified Meshtastic behavior uses PCAS11,3 for vehicle mode.
  if (strcmp(value, "vehicle") == 0 || strcmp(value, "Vehicle") == 0) {
    return 3;
  }

  if (value[0] >= '0' && value[0] <= '7' && value[1] == '\0') {
    return value[0] - '0';
  }

  return -1;
}

static bool rak12501SetL76KNavMode(uint8_t mode, bool send_now) {
  if (mode > 7) {
    return false;
  }

  rak12501_l76k_nav_mode = mode;
  if (send_now) {
    rak12501ApplyL76KNavMode();
  }
  return true;
}

static void rak12501ConfigureL76K() {
  MESH_DEBUG_PRINTLN("Configuring RAK12501/L76K GPS with Meshtastic-style init");

  // Meshtastic RAK3401/L76K style init:
  //   GPS + GLONASS + BeiDou
  //   RMC + GGA only
  //   Vehicle mode by default
  rak12501SendNMEA(Serial1, "PCAS04,7");
  delay(250);
  rak12501SendNMEA(Serial1, "PCAS03,1,0,0,0,1,0,0,0,0,0,,,0,0");
  delay(250);
  rak12501ApplyL76KNavMode();
  delay(250);
}
#endif
'''

if helper_marker not in text:
    insert_after = "static RAK12500LocationProvider RAK12500_provider;\n#endif\n"
    if insert_after not in text:
        raise SystemExit("Could not find RAK12500 provider block in EnvironmentSensorManager.cpp; upstream changed")
    text = text.replace(insert_after, insert_after + helper_block + "\n")

# Replace settings plumbing so the app can see and set gps, gps_interval, and L76K nav mode.
get_num = r'''int EnvironmentSensorManager::getNumSettings() const {
  int settings = 0;
  #if ENV_INCLUDE_GPS
    if (gps_detected) {
      settings++;  // gps enable/disable in the app
      settings++;  // gps_interval in seconds
      #ifdef RAK12501_L76K_GPS
      settings++;  // gps_vehicle_mode / L76K PCAS11 mode
      #endif
    }
  #endif
  return settings;
}

'''
get_name = r'''const char* EnvironmentSensorManager::getSettingName(int i) const {
  int settings = 0;
  #if ENV_INCLUDE_GPS
    if (gps_detected && i == settings++) {
      return "gps";
    }
    if (gps_detected && i == settings++) {
      return "gps_interval";
    }
    #ifdef RAK12501_L76K_GPS
    if (gps_detected && i == settings++) {
      return "gps_vehicle_mode";
    }
    #endif
  #endif
  return NULL;
}

'''
get_value = r'''const char* EnvironmentSensorManager::getSettingValue(int i) const {
  static char value[16];
  int settings = 0;
  #if ENV_INCLUDE_GPS
    if (gps_detected && i == settings++) {
      return gps_active ? "1" : "0";
    }
    if (gps_detected && i == settings++) {
      snprintf(value, sizeof(value), "%lu", (unsigned long)gps_update_interval_sec);
      return value;
    }
    #ifdef RAK12501_L76K_GPS
    if (gps_detected && i == settings++) {
      snprintf(value, sizeof(value), "%u", rak12501_l76k_nav_mode);
      return value;
    }
    #endif
  #endif
  return NULL;
}

'''
set_value = r'''bool EnvironmentSensorManager::setSettingValue(const char* name, const char* value) {
  #if ENV_INCLUDE_GPS
  if (gps_detected && strcmp(name, "gps") == 0) {
    if (strcmp(value, "0") == 0) {
      stop_gps();
    } else {
      start_gps();
    }
    return true;
  }

  if (gps_detected && strcmp(name, "gps_interval") == 0) {
    uint32_t interval_seconds = atoi(value);
    gps_update_interval_sec = interval_seconds > 0 ? interval_seconds : 1;
    return true;
  }

  #ifdef RAK12501_L76K_GPS
  if (gps_detected &&
      (strcmp(name, "gps_vehicle_mode") == 0 || strcmp(name, "gps_nav_mode") == 0)) {
    int mode = rak12501ParseL76KNavMode(value);
    if (mode < 0) {
      return false;
    }

    return rak12501SetL76KNavMode((uint8_t)mode, gps_active);
  }
  #endif
  #endif
  return false;  // not supported
}

'''
text = replace_function(text, "int EnvironmentSensorManager::getNumSettings() const {", "const char* EnvironmentSensorManager::getSettingName", get_num)
text = replace_function(text, "const char* EnvironmentSensorManager::getSettingName", "const char* EnvironmentSensorManager::getSettingValue", get_name)
text = replace_function(text, "const char* EnvironmentSensorManager::getSettingValue", "bool EnvironmentSensorManager::setSettingValue", get_value)
text = replace_function(text, "bool EnvironmentSensorManager::setSettingValue", "#if ENV_INCLUDE_GPS\nvoid EnvironmentSensorManager::initBasicGPS()", set_value)

# Add RAK12501/L76K init into the basic serial GPS path.
rak12501_init_block = r'''
  #ifdef RAK12501_L76K_GPS
  _location->begin();
  _location->reset();

  // RAK12501/L76K can take a moment before it will accept commands.
  delay(RAK12501_L76K_BOOT_DELAY_MS);
  rak12501ConfigureL76K();

  gps_detected = true;

  #if RAK12501_GPS_DEFAULT_ENABLE
    gps_active = true;
    return;
  #else
    _location->stop();
    gps_active = false;  // app can enable later with custom setting gps=1
    return;
  #endif
  #endif

'''
basic_anchor = '''  #endif

  // Try to detect if GPS is physically connected to determine if we should expose the setting
'''
if rak12501_init_block.strip() not in text:
    if basic_anchor not in text:
        raise SystemExit("Could not find initBasicGPS insertion point; upstream changed")
    text = text.replace(basic_anchor, "  #endif\n" + rak12501_init_block + "  // Try to detect if GPS is physically connected to determine if we should expose the setting\n", 1)

# Start GPS should run the same L76K init whenever the app enables GPS.
start_anchor = '''void EnvironmentSensorManager::start_gps() {
  gps_active = true;
'''
start_insert = r'''void EnvironmentSensorManager::start_gps() {
  gps_active = true;
  #ifdef RAK12501_L76K_GPS
    _location->begin();
    _location->reset();
    delay(RAK12501_L76K_BOOT_DELAY_MS);
    rak12501ConfigureL76K();
    return;
  #endif
'''
if start_insert not in text:
    if start_anchor not in text:
        raise SystemExit("Could not find start_gps insertion point; upstream changed")
    text = text.replace(start_anchor, start_insert, 1)

env_mgr_cpp.write_text(text)
print(f"patched {env_mgr_cpp}")

print("RAK3401 + RAK12501/L76K Meshtastic-style GPS patch complete")
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

Then open the MeshCore app and use the custom GPS settings:
  gps=1
  gps_interval=1
  gps_vehicle_mode=vehicle
EOF
