# MeshCore RAK3401 + RAK13302 1W Booster + RAK12501 GPS

This repository is now staged around an upstreamable MeshCore patch, not a private one-off firmware hack.

The source of truth is:

```text
patches/0001-rak3401-rak12501-l76k-gps.patch
```

That patch is intended to be applied against `meshcore-dev/MeshCore` and then opened as a pull request upstream.

## What the patch does

For the RAK WisMesh 1W Booster stack:

```text
RAK3401 core + RAK13302 1W SX1262/SKY66122 PA + RAK12501 GNSS
```

it adds a RAK12501 / Quectel L76K GPS path that:

- uses UART NMEA on the RAK3401 Serial1 pins,
- avoids the RAK12500/u-blox/I2C WisBlock GPS detection path,
- avoids using `WB_IO2 / PIN_3V3_EN` as a GPS power toggle because that rail is also needed by the RAK13302 1W PA path,
- sends a Meshtastic-style L76K init sequence,
- reduces GPS serial traffic to RMC + GGA only,
- exposes GPS controls through MeshCore's existing custom-variable path for the companion app.

## Companion app custom variables

After flashing a build with this patch, the companion app should be able to list and set:

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

Accepted `gps_vehicle_mode` values:

```text
0 / portable
1 / static
2 / walking / walk
3 / vehicle / car
4 / sea
5 / sea1g
6 / sea2g
7 / sea4g
```

`vehicle` maps to L76K mode `3`, matching the Meshtastic-style `$PCAS11,3` behavior.

## Build locally

```bash
git clone https://github.com/mathisono/Meshcore-RAK3401-RAK13302-1W-Booster-RAK12501.git
cd Meshcore-RAK3401-RAK13302-1W-Booster-RAK12501
chmod +x build-rak3401-rak12501.sh
./build-rak3401-rak12501.sh
```

Patch-only mode:

```bash
BUILD=0 ./build-rak3401-rak12501.sh
```

Use a local MeshCore checkout:

```bash
MESHCORE_DIR=~/MeshCore BUILD=0 ./build-rak3401-rak12501.sh
```

## Prepare an upstream PR

See [`UPSTREAM_PR.md`](UPSTREAM_PR.md).
