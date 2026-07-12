# Upstream PR preparation

Target upstream repository:

```text
https://github.com/meshcore-dev/MeshCore
```

Suggested PR title:

```text
Add RAK12501/L76K GPS support for RAK3401 1W Booster
```

## Summary

This patch updates the existing RAK3401 1W target so it can use the RAK12501 GNSS module through UART NMEA instead of the RAK12500/u-blox/I2C-oriented WisBlock GPS path.

The change is scoped to the RAK3401 variant and `EnvironmentSensorManager` GPS custom settings.

## Why

The RAK12501 is a Quectel L76K UART NMEA GNSS module. On the RAK3401 + RAK13302 1W Booster stack, `WB_IO2 / PIN_3V3_EN` must stay high because it also supports the RAK13302/SKY66122 PA rail. That means RAK12501 support should not try to use the shared 3V3 rail as a GPS-only enable or sleep pin.

## Behavior

The patch adds:

```ini
-D RAK12501_L76K_GPS=1
-D RAK12501_L76K_NAV_MODE=3
-D RAK12501_GPS_DEFAULT_ENABLE=0
```

and the L76K init sequence:

```text
$PCAS04,7                                  GPS + GLONASS + BeiDou
$PCAS03,1,0,0,0,1,0,0,0,0,0,,,0,0          RMC + GGA only
$PCAS11,3                                  vehicle mode
```

`$PCAS03` is the main GPS optimization here: it reduces serial traffic to just RMC and GGA, which is enough for MeshCore location telemetry while keeping the companion app responsive.

## Companion app controls

The existing custom-variable mechanism exposes:

```text
gps
gps_interval
gps_vehicle_mode
```

Examples:

```text
gps=1
gps=0
gps_interval=60
gps_vehicle_mode=vehicle
```

`gps_vehicle_mode` accepts numeric `0..7` or these aliases:

```text
portable, static, walking, walk, vehicle, car, sea, sea1g, sea2g, sea4g
```

## What is intentionally not done

This patch does not power down the RAK12501 by toggling `WB_IO2 / PIN_3V3_EN`. On the 1W Booster stack that rail is shared with the PA support rail, so turning it off as a GPS sleep mechanism is unsafe for radio operation.

This patch also does not add unverified L76K standby/sleep PCAS commands. `gps=0` disables MeshCore GPS use through the existing provider path, but it is not presented as guaranteed GNSS silicon deep sleep on this board.

## How to apply to a fork of MeshCore

From a MeshCore fork:

```bash
git clone https://github.com/<your-user>/MeshCore.git
cd MeshCore
git remote add upstream https://github.com/meshcore-dev/MeshCore.git
git fetch upstream
git checkout -b rak3401-rak12501-l76k-gps upstream/main
curl -L https://raw.githubusercontent.com/mathisono/Meshcore-RAK3401-RAK13302-1W-Booster-RAK12501/main/patches/0001-rak3401-rak12501-l76k-gps.patch | git apply
git add variants/rak3401/platformio.ini variants/rak3401/variant.h src/helpers/sensors/EnvironmentSensorManager.cpp
git commit -m "Add RAK12501 L76K GPS support for RAK3401"
git push -u origin rak3401-rak12501-l76k-gps
```

Then open a PR from:

```text
<your-user>:rak3401-rak12501-l76k-gps
```

to:

```text
meshcore-dev/MeshCore:main
```

## Suggested test commands

```bash
pio run -e RAK_3401_companion_radio_ble
pio run -e RAK_3401_companion_radio_usb
pio run -e RAK_3401_repeater
```

Runtime companion-app checks:

```text
GET_CUSTOM_VARS should include gps, gps_interval, gps_vehicle_mode
SET_CUSTOM_VAR gps:1 should initialize GPS
SET_CUSTOM_VAR gps_interval:60 should update the GPS telemetry interval
SET_CUSTOM_VAR gps_vehicle_mode:vehicle should send L76K mode 3 on next GPS start or immediately if GPS is active
```

Serial log to look for:

```text
Configuring RAK12501/L76K GPS
```
