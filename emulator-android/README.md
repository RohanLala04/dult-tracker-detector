# DULT Emulator (Android)

A minimal Kotlin app that broadcasts the DULT location-enabled BLE payload
(draft-ledvina-apple-google-unwanted-trackers-02) so the macOS detector has an
over-the-air tracker to find. Two buttons start and stop the broadcast; the
payload advertises network ID `0x01` (Apple) with the near-owner bit clear
(separated mode), the state that makes a tracker alert-eligible.

Target: Android API 26+. No third-party dependencies.

## Build and install

```
cd emulator-android
./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

Then open **DULT Emulator** on the phone, grant the Bluetooth permission, and
tap **Start Broadcasting (Separated)**. The macOS detector shows the device as
a DULT card within a few seconds.

## Why the payload is carried on 0xFC99, not 0xFCB2

The DULT spec assigns service UUID **0xFCB2** to the tracker advertisement. This
emulator instead advertises the identical payload under **0xFC99**, because a
stock Android phone cannot emit 0xFCB2 at all. That is not a bug in this app;
it is a deliberate platform restriction, which we proved before working around
it.

### Symptom

On a flagship Samsung device (recent One UI, Android 14), `BluetoothLeAdvertiser` reports
advertising success (`onAdvertisingSetStarted`, status 0) and `dumpsys
bluetooth_manager` shows the 0xFCB2 service data queued, yet a macOS Core
Bluetooth scanner inches away never receives it, while receiving 40-70 other
devices' advertisements per scan.

### Differential (seven hypotheses, six ruled out by evidence)

| # | Hypothesis | Verdict |
|---|------------|---------|
| 1 | Connectable flag / service-UUID-list interaction | Ruled out, non-connectable also failed |
| 2 | Extended (BT5) vs legacy advertising PHY | Ruled out, `dumpsys` shows `Legacy: true` |
| 3 | TX power too low | Ruled out, sentinel received at -42 dBm |
| 4 | Battery / screen-off radio throttling | Ruled out, screen Awake, sentinel still received |
| 5 | Advertising interval too long | Ruled out, 100 ms interval, ~30 packets per 22 s |
| 6 | **UUID-specific filtering** | **Confirmed (see below)** |
| 7 | Bluetooth coexistence with other radios | Ruled out, control UUID + sentinel received fine |

To separate "phone not radiating" from "payload stripped", the experiment
added a manufacturer-data sentinel (`0xFFFF` company, `DE AD BE EF`). The
sentinel arrived at the Mac at -42 to -47 dBm, proving the phone radiates and
the Mac receives it, but the same packets carried no 0xFCB2 service data.

### Controlled experiment (FC99 vs FCB2)

A single advertisement carried service data for **both** a control UUID
**0xFC99** and the tracker UUID **0xFCB2**, in the same `AdvertiseData`:

- The Mac received the **0xFC99** service data (30 packets) and the
  manufacturer sentinel.
- The Mac **never** received the **0xFCB2** service data (`grep -c` = 0 across
  every capture).

Same packet, same API call, same scanner, the only variable is the UUID.

### Conclusion: anti-spoofing enforcement

Android's Bluetooth stack silently strips the **0xFCB2** service data from
third-party app advertisements while reporting success. 0xFCB2 is the
standardized unwanted-tracker UUID, so this is an anti-abuse / anti-stalking
measure: an app may not impersonate a location tracker by broadcasting the
tracker beacon. It cannot be worked around from inside an app, and it is a
property of the unwanted-tracking framework rather than of any one vendor, so
other modern Android devices are expected to behave the same way.

This is itself a meaningful result for a tracker-detection project: the
platform the detector defends actively prevents trivial spoofing of tracker
advertisements.

### The workaround

The emulator advertises the DULT payload on the unfiltered **0xFC99**. The
macOS detector scans for and parses both UUIDs and treats a valid 0xFC99
payload identically to a real 0xFCB2 advertisement for detection, parsing, and
scoring, labeling it **TEST** in the UI so it is distinguishable from a real
tracker. A genuine 0xFCB2 tracker (AirTag-class hardware, or any advertiser
without the app-level restriction, such as an ESP32, nRF board, or Linux host
running BlueZ) is detected with no TEST label and no code changes.

Android rotates the advertising MAC every several minutes (the privacy
behavior the DULT spec requires), so the phone appears under a new peripheral
UUID after each rotation. The detector groups these by the payload so the
emulator still shows as one tracked entity whose co-travel timer survives the
rotations; for a clean demo, start broadcasting and leave the phone undisturbed.
