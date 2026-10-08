# Patches

Patches applied on top of BASE.env. Each entry's `source` is an upstream URL pinned
to a commit, or `armada` if it's original; a URL source with no `notes` is verbatim.
`notes` mean the file was modified.

- `patches/0001-fix-gamepad-share-raw-input.patch`
  source: armada
- `patches/0002-fix-force-feedback-reset-effects-when-replacing-targets.patch`
  source: armada
- `patches/0003-fix-AyaneoHaptics-sleep-between-polls.patch`
  source: armada
- `patches/0004-fix-Hardware-Support-KONKR-Pocket-FIT-MCU-system-buttons.patch`
  source: armada
- `patches/0005-feat-source-add-Qualcomm-SSC-IMU-source.patch`
  source: armada
  notes: `ssc` source device reading accel/gyro from the Qualcomm Sensor Core over QRTR, anchored on the `fastrpc-*dsp` misc device, streams a sensor only while a target uses motion and the sensor is not filtered
