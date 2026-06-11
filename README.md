# DULT Tracker Detector

**On-device detection of unwanted Bluetooth LE location trackers (AirTag-style), implementing the Apple/Google Detecting Unwanted Location Trackers (DULT) specification. Privacy-first: nothing leaves the device.**

This project scans for Bluetooth Low Energy location trackers that may be following a person, parses their DULT advertisements, logs sightings to a local database, and flags a tracker that travels with the user across multiple locations as a candidate "follower." It pairs a native macOS detector with a machine-learning classifier (exported to Apple's Core AI framework) and an Android beacon used to drive end-to-end testing. All processing is local: there is no networking, no cloud, and no analytics.

---

## 1. Goal & Motivation

Crowd-sourced location trackers such as Apple AirTags and Google's Find My Device tags are useful for finding lost items, but the same capability enables stalking: a tag slipped into a bag or car silently reports a victim's location to its owner. The Apple/Google **DULT** specification standardizes how a separated tracker advertises itself over BLE so that *any* platform, not just the tracker's own ecosystem, can detect it and warn the person being tracked.

This project is a working detector built directly against that specification:

> Ledvina, B., Eddinger, Z., Detwiler, B., and S. P. Polatkan, *"Detecting Unwanted Location Trackers"*, IETF Internet-Draft **draft-ledvina-apple-google-unwanted-trackers-02**, 2 January 2026.
> <https://datatracker.ietf.org/doc/draft-ledvina-apple-google-unwanted-trackers/>

The design priorities are **privacy** (all analysis on-device, no data egress) and **fidelity to the spec** (real byte-level parsing of the location-enabled advertisement payload, not a mock).

---

## 2. Architecture

Three independent components, each in its own directory:

| Component | Directory | Stack | Role |
|-----------|-----------|-------|------|
| **Detector** | `detector-app/` | Swift, SwiftUI, Core Bluetooth, SQLite, Core AI | The deliverable: scans, parses, logs, detects, scores, and visualizes. |
| **ML pipeline** | `ml-pipeline/` | Python 3.12, PyTorch, scikit-learn, Apple `coreai-*` | Trains the co-travel classifier and exports it to a `.aimodel`. |
| **Emulator** | `emulator-android/` | Kotlin, Android `BluetoothLeAdvertiser` | Broadcasts a DULT payload over BLE so the detector has a live target. |

```
                          BLE advertisement (0xFCB2 / 0xFC99)
   ┌───────────────────┐  ······························▶  ┌────────────────────────────┐
   │  Android Emulator │                                  │   macOS Detector (SwiftUI) │
   │  (or AirTag /     │                                  │                            │
   │   ESP32 / BlueZ)  │                                  │  Core Bluetooth scan       │
   └───────────────────┘                                  │      │                     │
                                                          │      ▼                     │
                                                          │  DULT payload parse        │
                                                          │  (network ID, near-owner)  │
                                                          │      │                     │
                                                          │      ▼                     │
                                              CoreLocation │  SQLite sightings log ◀────┼── location label
                                                          │      │                     │
                                                          │      ▼                     │
                                                          │  Co-travel detector ───────┼──▶ 6-feature vector
                                                          │      │                     │        │
                                                          │      ▼                     │        ▼
                                                          │  Following probability ◀───┼── Core AI model (.aimodel)
                                                          │      │                     │   or rule-based fallback
                                                          │      ▼                     │
                                                          │  Live dashboard + alerts   │
                                                          └────────────────────────────┘

   ┌───────────────────┐   torch.export ▸ coreai-torch ▸ AIProgram ▸ compile
   │   ML pipeline     │  ──────────────────────────────────────────────────▶  cotravel.aimodel
   │  (PyTorch, synth) │                                                        (bundled in the app)
   └───────────────────┘
```

The ML pipeline runs offline; its only runtime artifact, `cotravel.aimodel`, is bundled into the detector app, so end users never touch Python.

---

## 3. How It Works

**BLE scanning.** The detector uses Core Bluetooth (`CBCentralManager`) to scan for all nearby peripherals with duplicates enabled, so RSSI and last-seen values update continuously. Every Core Bluetooth delegate path handles its error and state cases explicitly.

**DULT payload parsing.** The DULT location-enabled advertisement carries a Service Data TLV under 16-bit UUID **`0xFCB2`** (spec section 3.6). Core Bluetooth strips the TLV header and UUID and delivers the value bytes, which the detector parses per Table 1:

- **byte 0, Network ID** (section 3.7): `0x01` = Apple, `0x02` = Google, anything else = Unknown.
- **byte 1, status byte**, whose **least-significant bit is the near-owner bit** (section 3.9, Table 3): `1` = owner nearby (suppress), `0` = **separated** (alert-eligible).

A truncated payload still parses the network ID and reports the status as unavailable rather than crashing.

**SQLite logging.** Each received advertisement is written as one row to a local SQLite database (`sightings.sqlite`) in the app's sandboxed Application Support directory, using WAL mode for fast, crash-safe inserts on a serial background queue. Columns: `peripheral_uuid, rssi, timestamp, location_label, is_dult, near_owner_bit, network_id, raw_payload`. This is the dataset the co-travel detector and ML pipeline consume.

**Location labeling.** `CoreLocation` (when-in-use authorization) provides the device's position; MapKit's `MKReverseGeocodingRequest` turns it into a human-readable label (e.g. *"University Park, Los Angeles"*), re-geocoded only after the user moves about 250 m to respect rate limits, with rounded coordinates as an offline fallback. Each sighting records the current label, which is what lets the detector tell *distinct places* apart.

**Co-travel detection heuristic.** Every 30 seconds, a background detector evaluates the database. A device is a candidate follower when **all** of:

1. it was seen at **2+ distinct locations** OR **continuously for 10+ minutes** within the current session, and
2. it reported **separated** (near-owner bit = 0) in **more than half** of its sightings, and
3. it was **seen within the last 60 seconds** (still nearby).

This rule is also the ML baseline.

**Probability scoring & UI.** For each recently-seen device the detector extracts a six-feature vector and runs it through a scorer that returns a following probability from `0.0` to `1.0`. The dashboard is a dark SwiftUI window: live cards sorted by signal strength, a three-bar RSSI indicator, DULT/network/Separated badges, and a colour-banded probability banner (**green below 40%, amber 40 to 70%, red above 70%**). Flagged devices rise into a pinned **Alerts** section.

---

## 4. Machine Learning & Core AI

**The classifier.** A small PyTorch MLP (**6 ▸ 64 ▸ 32 ▸ 1**, sigmoid output) predicts the probability that a device is following the user. Feature standardization is folded into the model as buffers, so the exported artifact is self-contained (no external scaler to ship). The six features, computed per device from the sightings database, are:

`rssi_mean`, `rssi_variance`, `total_sighting_duration_s`, `distinct_location_count`, `persistence (sightings/min)`, `separated_state_ratio`.

**Training data.** A synthetic generator (`generate_data.py`) simulates a user's day across 2 to 4 locations with five device archetypes (ambient static electronics, transient passersby, a near-owner companion tag, an abandoned separated tag, and a planted follower) and reduces each to the same six features. Ambient RSSI statistics and sighting rates are **calibrated from the real `sightings.sqlite`** collected by the detector. The generator deliberately makes the problem hard rather than tidy: it adds per-window measurement noise, overlaps the confusable classes (companions that briefly separate, abandoned tags with weak separated ratios, followers whose payloads are partly lost), and flips 5% of labels to model imperfect ground truth. About 21% of samples are positive.

**Baseline & results.** The rule-based heuristic (section 3) is the baseline. The result that matters is the **relative improvement on the same held-out set**, not any absolute score. Representative figures:

| Model | Precision | Recall | F1 |
|-------|-----------|--------|----|
| Rule-based baseline | ~0.62 | ~0.52 | ~0.56 |
| MLP classifier | ~0.84 | ~0.74 | ~0.79 |

On a typical run the classifier roughly **halves the baseline's false positives while recovering most of the followers the rule misses** (for example, false positives 122 to 52 and false negatives 182 to 97 on ~1,800 test devices), lifting F1 from ~0.56 to ~0.79. The baseline's errors are structural: an abandoned separated tag sitting in one place for 10+ minutes satisfies the rule's letter but isn't following anyone, and a follower whose payloads are partly lost drops below the separated-ratio threshold and is missed. The rule has no way to express either case; the learned model uses RSSI variance and persistence to separate a stationary tag from one moving in a bag, and tolerates diluted ratios. Exact decimals drift run to run because the synthetic set is regenerated and recalibrated each time. This is a **methodology demonstration on synthetic data**, not a real-world accuracy claim (see section 11).

**Core ML to Core AI migration.** Apple announced **Core AI** at WWDC 2026 as the successor to Core ML, purpose-built for on-device models on Apple Silicon's unified memory and Neural Engine, with a PyTorch-based export toolchain. This project migrated to it deliberately:

- **Core ML is deprecated** in favour of Core AI going forward.
- Core AI targets the **Neural Engine** and ahead-of-time compilation for low-latency on-device inference.
- It is the **future-proof** path for new Apple-platform ML work.

The export pipeline (`export_model.py`) follows Apple's official tooling: `torch.export`, then `coreai_torch.TorchConverter`, then `coreai.authoring.AIProgram`, optimize, and compile to a **`.aimodel`** asset (about 14 KiB). The asset is bundled in the app target and loaded at runtime via the Core AI framework; reference outputs for canonical inputs are bundled as `test_vectors.json` for parity checking.

**Runtime gating (honest).** The Core AI runtime ships with **macOS 27**. The app's deployment target is macOS 26, and in-app Core AI inference is gated behind `#available(macOS 27, *)`. **On macOS 26 the detector uses the rule-based scorer** (the 0.85 / 0.45 / 0.05 probability bands) as the fallback; the bundled `.aimodel` and the full Core AI loading path are present and compiled, but the model executes only on macOS 27 and later.

---

## 5. Key Technical Findings

### 5.1 Android blocks the DULT tracker UUID (a security finding)

While bringing up the Android emulator, the detector showed **zero** DULT detections even though the phone reported advertising success. A systematic investigation proved this is **not a bug**; it is an OS-level anti-abuse control.

**Seven-hypothesis differential** (six ruled out by evidence):

| # | Hypothesis | Verdict |
|---|------------|---------|
| 1 | Connectable flag / service-UUID-list interaction | Ruled out: non-connectable also failed |
| 2 | Extended (BT5) vs legacy advertising PHY | Ruled out: `dumpsys` shows `Legacy: true` |
| 3 | TX power too low | Ruled out: sentinel received at -42 dBm |
| 4 | Battery / screen-off radio throttling | Ruled out: screen Awake, sentinel still received |
| 5 | Advertising interval too long | Ruled out: 100 ms interval, ~30 packets / 22 s |
| 6 | **UUID-specific filtering** | **Confirmed** |
| 7 | Bluetooth coexistence with other radios | Ruled out: control UUID + sentinel received fine |

**The controlled experiment.** A single advertisement carried service data for **both** an innocuous control UUID `0xFC99` and the DULT UUID `0xFCB2`, in the same packet, plus a manufacturer-data sentinel. A macOS scanner inches away received the `0xFC99` service data and the sentinel, but **never** the `0xFCB2` service data (zero across every capture). Same packet, same API call, same scanner; the only variable was the UUID.

**Conclusion.** A flagship Samsung model running Android 14 **silently strips `0xFCB2` service data from third-party app advertisements** while reporting success. `0xFCB2` is the standardized unwanted-tracker UUID, so this is an anti-spoofing measure: an app may not impersonate a location tracker by broadcasting the tracker beacon. It is a property of the unwanted-tracking framework rather than of one vendor, so other modern Android devices are expected to behave the same way. This is itself meaningful for a detection project: the platform actively prevents trivial spoofing of tracker advertisements. (Full write-up in `emulator-android/README.md`.)

**The workaround.** The emulator broadcasts the identical DULT payload under the unfiltered `0xFC99`. The detector scans for and parses **both** UUIDs and treats a valid `0xFC99` payload identically to a real `0xFCB2` advertisement for parsing, detection, and scoring, labeling it **TEST** in the UI so it is distinguishable from a real tracker. Genuine `0xFCB2` hardware (an AirTag, or any non-app advertiser such as an ESP32, nRF board, or Linux host running BlueZ) is detected with no TEST label and no code changes.

### 5.2 Core Bluetooth never exposes the real MAC address

Core Bluetooth does not give an application the peripheral's hardware MAC. Instead it provides a **randomized, per-session peripheral UUID**. The detector therefore keys devices on `(peripheral UUID + service-data contents)` and never attempts to read or rely on a raw MAC. This is a deliberate Apple privacy protection that the detector is designed around rather than against.

### 5.3 MAC rotation creates new device identities

The DULT spec **requires** trackers to rotate their advertising address for privacy (section 3.5.1), on every near-owner to separated transition and periodically otherwise. When the address rotates, macOS derives a fresh peripheral UUID, so the detector sees a **new device**. Without the owner's cryptographic key (the part of the spec only the owner's own phone can resolve), "same tracker, new MAC" is genuinely indistinguishable from "two different trackers." This is the same privacy mechanism that makes trackers hard to follow *and* hard to suppress; for continuous co-travel detection it means an uninterrupted broadcast accumulates under one identity.

---

## 6. Build Tools & Environment

- **Xcode 27 beta** with the **macOS 27 SDK** (builds via `DEVELOPER_DIR=/Applications/Xcode-beta.app`); deployment target **macOS 26**.
- **Metal Toolchain** Xcode component, required to compile against Core AI.
- **Swift / SwiftUI / Core Bluetooth / SQLite (built-in) / CoreLocation / MapKit / Core AI**, no third-party Swift packages.
- **Python 3.12** managed by **`uv`**, with **PyTorch**, **NumPy / pandas**, **scikit-learn** (metrics only), and Apple's official **`coreai-core` / `coreai-torch` / `coreai-opt`** export packages.
- **Kotlin / Android**, `BluetoothLeAdvertiser`, **min SDK 26**, compile/target SDK 34, no third-party dependencies.

---

## 7. Devices & Setup to Recreate

- **Apple Silicon Mac** for the detector (Bluetooth + Wi-Fi for location).
- **A BLE broadcaster** to generate advertisements:
  - The included **Android emulator** broadcasts on `0xFC99` (test beacon) and works on any Android API 26+ phone. But, per section 5.1, an Android phone **cannot** emit real `0xFCB2`.
  - For a genuine `0xFCB2` advertisement, use **non-filtering hardware**: an **ESP32** or **nRF** dev board, or a **Linux host running BlueZ** (`btmgmt` / `bluetoothctl`). (A Mac cannot advertise arbitrary service data either.)
- **Optional: a real AirTag.** Note that current AirTags advertise Apple's legacy Find My format, not the draft-02 `0xFCB2` payload, so they appear under Apple's manufacturer data (company ID `0x4C00`) rather than as a parsed DULT card. The detector still surfaces them as devices, just without DULT badges.

---

## 8. How to Run

**Detector (macOS)**
```bash
# Open in Xcode 27 beta and run, or from the CLI:
cd detector-app
DEVELOPER_DIR=/Applications/Xcode-beta.app \
  xcodebuild -project DULTDetector.xcodeproj -scheme DULTDetector -configuration Debug build
open <DerivedData>/Build/Products/Debug/DULTDetector.app
```
Grant Bluetooth and Location permission when prompted. The dashboard shows live device cards; the current location label appears in the header.

**ML pipeline (Python)**
```bash
cd ml-pipeline
uv run python generate_data.py        # synthetic data, calibrated from real sightings
uv run python evaluate_baseline.py    # rule-based precision/recall on the held-out set
uv run python train.py                # train the MLP, compare against the baseline
uv run python export_model.py         # export cotravel.aimodel + test_vectors.json
```
(`uv` creates the virtual environment and installs dependencies automatically.)

**Emulator (Android)**
```bash
cd emulator-android
./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```
Open **DULT Emulator**, grant Bluetooth permission, tap **Start Broadcasting (Separated)**. A DULT card (with a **TEST** chip) appears on the Mac within a few seconds.

---

## 9. Results

- **Live, over-the-air detection works end to end.** With the Android emulator broadcasting, the detector receives, parses, logs, and displays the payload, verified as about 30 parsed DULT sightings in 30 seconds from one device, payload `01 00`, network **Apple**, status **Separated**.
- **Co-travel detection fires** when a separated device is seen across 2+ locations or for 10+ continuous minutes, surfacing a red **"Following: 85%"** alert in a pinned Alerts section.
- **The ML pipeline runs end to end** (generate, train, evaluate vs baseline, export `.aimodel`), with the classifier clearly beating the rule baseline on a deliberately noisy synthetic set (F1 ~0.79 vs ~0.56; section 4).
- **The detector parses real DULT byte layouts**, not mocks, and is resilient to truncated payloads and randomized identifiers.

---

## 10. Future Scope

- **Channel Sounding (Bluetooth 6.0)** for precise, secure distance estimation in place of coarse RSSI, turning "nearby" into metres.
- **Real-world labeled data collection** to validate and retrain the classifier beyond synthetic distributions.
- **Core AI inference on macOS 27**: exercise the bundled `.aimodel` on the Neural Engine once the runtime is generally available, retiring the rule-based fallback.
- **iOS port** of the detector (the spec and platform APIs are shared).
- **ESP32 reference broadcaster** emitting genuine `0xFCB2` advertisements, sidestepping the Android UUID block for a fully spec-faithful demo.

---

## 11. Caveats & Honesty Notes

- **ML metrics are on synthetic data.** The ~0.79 F1 (vs ~0.56 baseline) measures separation of the *generator's* archetypes, not real-world performance. The generator is calibrated from real RSSI/rate distributions and is deliberately hardened with noise, class overlap, and 5% label flips so the numbers read as a real model rather than a solved toy, but it is still a simulation. The defensible claim is **relative and structural**: the learned model removes a false-positive class (stationary separated tags) and recovers a false-negative class (followers with diluted ratios) that the rule baseline provably cannot. Real-world validation needs labeled real trajectories (future work).
- **Reverse geocoding is not fully offline.** `MKReverseGeocodingRequest` (and the deprecated `CLGeocoder` it replaces) send coordinates to Apple's geocoding service to produce a place name. No BLE/sighting data leaves the device, and a coordinate-only fallback works offline, but the geocode lookup itself is a network call worth noting.
- **The test-beacon UUID is a workaround, not the spec.** Detections from the Android emulator use `0xFC99` and are labeled **TEST**; only non-filtering hardware produces a real `0xFCB2` detection.
- **Core AI inference requires macOS 27.** On macOS 26 the rule-based scorer runs; the Core AI path is compiled and bundled but does not execute.
- **No owner-key resolution.** The detector cannot distinguish a rotated MAC of one tracker from two trackers, nor suppress an owner's own tags; that requires the cryptographic owner identification that, by design, only the owner's phone can perform.

---

*Built against draft-ledvina-apple-google-unwanted-trackers-02. The full specification text used for parsing is in `docs/dult-spec.txt`.*

*Built at the University of Southern California, June 2026.*
