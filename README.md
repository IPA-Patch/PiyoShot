<h1 align="center">PiyoShot</h1>

<p align="center">
  <img src="icon.webp" alt="PiyoShot icon" width="180" />
</p>

<p align="center">
  <em>Batch-capture <strong>PiyoShogi</strong> board positions to PNG,<br/>
  driven by a JSONL of SFEN records.<br/>
  Client-side, autonomous, ~24 min per 10 000 records.</em>
</p>

<p align="center">
  <img alt="version" src="https://img.shields.io/badge/version-v0.1.0-2f80ed?style=flat-square" />
  <img alt="targets PiyoShogi" src="https://img.shields.io/badge/targets-PiyoShogi%205.7.5%20(199)-ff66a3?style=flat-square" />
  <img alt="platform" src="https://img.shields.io/badge/platform-iOS%2015.0%E2%80%9326-blue?style=flat-square" />
  <img alt="arch" src="https://img.shields.io/badge/arch-arm64%20rootless-555?style=flat-square" />
  <img alt="runs" src="https://img.shields.io/badge/runs-client--side%20only-1f9d55?style=flat-square" />
  <img alt="scope" src="https://img.shields.io/badge/scope-authorized%20research%20only-c69214?style=flat-square" />
</p>

[日本語版はこちら](README.ja.md)

---

**PiyoShogi (ぴよ将棋)** is an offline shogi app by Studio Ki, available on the
[App Store](https://apps.apple.com/jp/app/id792887995).

PiyoShot is a research tool that automates PiyoShogi's own **"load KIF from
clipboard"** flow: for each record in a JSONL of `{sfen, hash}` entries the
tweak sets the pasteboard, fires `-[VCTopMenu btnKifPasteClicked:]`, forces
the board layer to redraw against the freshly-parsed `Position`, and writes
a PNG of either the whole key window or the `ShogiBoardView` alone to
`Documents/piyo_capture/{screen,board}/<hash>.png` depending on the current
capture mode. The generated image corpus is intended for board-state OCR
training and similar research; it never leaves the device on its own.

## Features

| Feature | What it does |
|---|---|
| **JSONL Loader** | Pick a `.jsonl` (`{"sfen": "…", "hash": "…"}` per line) via the document picker, or auto-load the 10 000-record default bundled inside the deb / IPA. Every line is streaming-validated: total / valid / invalid / captured / remaining are displayed. |
| **Capture Mode** | Segmented Control (**Screen** / **Board**) persisted in `NSUserDefaults`. Screen writes the full `UIWindow`; Board writes just the `ShogiBoardView` subtree, tightly cropped. Each mode has its own output directory and resume state. |
| **Batch Runner** | Iterates the loaded JSONL one record at a time. Sets the pasteboard, fires `btnKifPasteClicked:`, waits for the 3rd `parseSFEN` (final redraw prep) to return, forces `ShogiBoardView` to repaint, and PNG-writes to `piyo_capture/<mode>/<hash>.png`. Fire-and-forget, resume-safe, no cancel API by design. |
| **Progress Overlay** | Bottom-centre banner (`N/total · rate/s · ETA hh:mm`) painted on a transparent alert-level `UIWindow` so you can leave the device unattended and read progress at a glance. |
| **Hash-based Dedup** | SHA-256 walks the current mode's output dir and drops every duplicate content group (byte-identical PNGs prove one record's SFEN is wrong — and we can't tell which is honest, so we drop all members). The runner's upfront filter recaptures the freed hashes on the next pass. |
| **Ad Suppression** | Always-on ObjC runtime swizzle that skips ad SDKs' `-layoutSubviews` and NoOps their load methods, so the banners' pulsate / fade animations no longer contest the render server. Cuts per-record wall-clock from ~350 ms → ~143 ms on iPhone 8 — a pure capture-throughput optimisation, no visual side-effects on stock use. |

## Capture modes

The Capture Mode Segmented Control writes to distinct sandbox
subdirectories, and each mode has independent resume state.

| Mode | Output dir | Snapshot target |
|---|---|---|
| **Screen** (default) | `Documents/piyo_capture/screen/` | Full `UIWindow` (board + surrounding UI chrome) |
| **Board** | `Documents/piyo_capture/board/` | `ShogiBoardView` subtree only, tightly cropped |

The mode is snapshotted at batch start — mid-run switches never produce a
mixed-mode batch, and the segment is disabled while a run is live.
Board mode refuses to fall back to the full window if `ShogiBoardView`
can't be found on that iteration (skips the record instead) so
mode-mixed PNGs never sneak into `piyo_capture/board/`.

### Known issue: crash around iteration 4841

On the **CHINLAN sideload IPA** running against PiyoShogi 5.7.5, the batch
deterministically aborts at roughly iteration **4841** — beyond ~4800
successive paste iterations the app raises an unhandled `NSException`
inside `-[UINib instantiateWithOwner:options:]` and crashes. The tweak
installs its own `NSSetUncaughtExceptionHandler` (chained ahead of
Firebase Crashlytics, so upstream reporting still fires) purely to log
the exception name / reason / call stack to `piyoshot.log` — the crash
itself is not yet fixed.

Practical workaround: cap each batch under ~4800 valid records, or
launch the app fresh between runs — the resume-safe filter picks up
where the previous session left off, so no captured PNGs are lost.

## Data model

**Input** (`position.jsonl`):

```jsonl
{"sfen": "+R2+S2s1l/4skg2/p1ppppnp1/1N4p1p/4Sr3/Pp6P/G2KP1PL1/7P1/LN4GNL b 2BG3Pp 71", "hash": "e3fc4e063461f3cff91f43b61b25b670c74579ae7db87c22acf5c6c41edbcd13"}
{"sfen": "…", "hash": "…"}
```

`hash` is `sha256(sfen)` — the canonical filename for the captured PNG.

**Output** (per capture mode):

```
Documents/piyo_capture/
├── screen/
│   ├── 0023de78ce60092ab28c75c203e90427dd68a7ee4cfff720125d73f4676abfb9.png
│   ├── 00ff8c4b…png
│   └── e3fc4e06…png                          ← <hash>.png
└── board/
    ├── 0023de78…png
    └── e3fc4e06…png                          ← <hash>.png (board crop)
```

Interrupted runs pick up where they left off — the upfront filter drops
records whose PNG already lives on disk in the **current mode's** output
directory before iteration starts. Each mode resumes independently.

Both distribution flavors bundle a default JSONL. The Sheet auto-detects it
at:

- **JB rootless deb**: `/var/jb/Library/Application Support/PiyoShot/position.jsonl`
- **CHINLAN sideload IPA**: `Payload/PiyoShogi.app/Frameworks/position.jsonl` (sibling of the injected `PiyoShot.dylib`)

## Settings UI

Right-edge left swipe (30 pt hit strip, 80 pt trigger distance) → settings
sheet with four inset-grouped sections:

- **JSONL** — Choose JSONL file (opens the document picker), the loaded
  filename, and the `total / valid / invalid` line stacked over
  `captured / remaining`. Bundled default auto-loads on first present.
- **Capture** — Screen / Board Segmented Control (persisted, disabled
  during a live run).
- **Run** — *Run* (labelled `Run (N remaining)`, disabled when nothing is
  left to capture); *Hash check (dedupe)* (systemRed to signal
  destructiveness); *Status* (last runner message).
- **Info** — Version / Commit / on-device log path — separate rows so
  `v0.1.0` and the build hash never blur together.

All batch progress is painted on the overlay window's bottom-centre
banner, not the sheet — the sheet dismisses itself before iteration
starts so PiyoShogi has the whole screen back.

## Compatibility

| | |
|---|---|
| **Target PiyoShogi** | `5.7.5` (CFBundleVersion 199), bundle id `net.studioki.PiyoShogi` |
| **PiyoShogi minimum iOS** | 13.0 (`MinimumOSVersion` in app bundle) |
| **PiyoShot minimum iOS** | 15.0 (requires `UIWindowScene`) |
| **Tested on** | iOS 15.0 – 26, arm64 |
| **Distribution** | Jailbroken rootless `.deb`, CHINLAN Patched IPA (TrollStore / Sideloadly / AltStore) |

Distribution flavors compared:

| Flavor | For | How |
|---|---|---|
| **JB rootless deb** | Jailbroken devices (Dopamine, rootless) | `MSHookFunction` via libsubstrate. Install with Sileo / Zebra. |
| **CHINLAN sideload IPA** | Non-jailbroken devices, iOS 15 – 26 | Statically-patched PiyoShogi binary that routes hook sites through a `__DATA` slot table so the runtime never rewrites `__TEXT` (which iOS 18+'s Code Signing Monitor blocks). Install with TrollStore, Sideloadly, or AltStore. |

## Build

Requires the Theos toolchain (Linux devcontainer supported — see
`.devcontainer/`) and, for the CHINLAN IPA build, Python 3.12 with the
pinned `pyproject.toml` deps.

### Jailbroken device (rootless)

`make FINALPACKAGE=1 package install` builds the release `.deb` and
transfers it over SSH. Devcontainer users get `host.docker.internal:2222`
wired as the default target — configure `iproxy 2222 22` on the host.

```sh
# release .deb
make FINALPACKAGE=1 package

# build + install over usbmuxd / iproxy
make FINALPACKAGE=1 package install \
    THEOS_DEVICE_IP=192.168.x.x THEOS_DEVICE_PORT=22
```

Debug builds omit `FINALPACKAGE=1` and land at `0.1.0-dbg-N+debug`.

### Patched IPA (Sideload / TrollStore)

Requires a **decrypted** PiyoShogi IPA (App Store copies are
FairPlay-encrypted and can't be patched directly). Install the patched
IPA with [TrollStore](https://github.com/opa334/TrollStore),
[Sideloadly](https://sideloadly.io/), or [AltStore](https://altstore.io/).

```sh
# release IPA
make FINALPACKAGE=1 ipa DECRYPTED_IPA=/path/to/PiyoShogi-5.7.5.ipa
# -> packages/ipa/PiyoShot-patched.ipa
```

`make ipa` calls `shared/tools/build_patched_ipa.sh` (from the
[Kanade](https://github.com/IPA-Patch/Kanade) submodule) which
statically rewrites the PiyoShogi binary's hook sites into a `__DATA`
slot table, injects `PiyoShot.dylib`, and drops `position.jsonl` next to
it inside `Payload/PiyoShogi.app/Frameworks/`.

## Architecture

- **`Sources/PiyoShot/PiyoOverlay.m`** — always-on transparent `UIWindow` (Alert + 1000 level) with a right-edge hit strip. The right-side pan recogniser presents `PiyoSheetVC`; no other touch passes through.
- **`Sources/PiyoShot/PiyoSheetVC.m`** — inset-grouped table with the JSONL / Capture / Run / Info sections. Reuses one `PiyoBatchRunner` across taps. The Capture segment is disabled while a batch is live so the mode can't drift out of sync with the runner's snapshotted output dir.
- **`Sources/PiyoShot/PiyoBatchRunner.m`** — main-queue iterator. Sets the pasteboard, invokes `btnKifPasteClicked:`, installs a `PSParseSFENCallback` that fires the snapshot as soon as the 3rd `parseSFEN` (final redraw prep) returns, forces `ShogiBoardView setNeedsDisplay + displayIfNeeded + layoutIfNeeded`, and writes the PNG to the current mode's output dir. Board mode refuses to fall back to the full window when the `ShogiBoardView` can't be found (so mode-mixed captures never sneak into `piyo_capture/board/`). The per-file autoreleasepool inside the Hash-check loop over `piyo_capture/<mode>/` is load-bearing on CHINLAN — the sandbox OOMs a few thousand files in without it.
- **`Sources/PiyoShot/Hook/AdHide.m`** — pure runtime ObjC swizzle that skips ad SDKs' `-layoutSubviews` and NoOps their load methods. Cuts per-record wall-clock from ~350 ms to ~143 ms on iPhone 8 because the ad banners' pulsate / fade animations no longer contest the render server.
- **`Sources/PiyoShot/Hook/ParseSFEN.m`**, **`Sources/PiyoShot/Hook/Validator.m`** — the two version-pinned RVAs the runner hangs off of. See `binpatch_sites.h`.
- **`Sources/Chinlan/`** submodule ([IPA-Patch/Chinlan](https://github.com/IPA-Patch/Chinlan)) — shared cave-hook runtime + logging.
- **`shared/`** submodule ([IPA-Patch/Kanade](https://github.com/IPA-Patch/Kanade)) — Python static-patcher tooling. `make ipa` calls `shared/tools/build_patched_ipa.sh` under the hood.

## Client-side only

PiyoShot touches **process memory** and **files inside the app's own sandbox** — nothing else. The tweak does **not**:

- Craft or send requests to PiyoShogi's servers.
- Replay captured requests.
- Proxy or MITM any network path.
- Mutate account-linked data or server-side state.

Turn every hook off and relaunch, and you're back to stock PiyoShogi.
