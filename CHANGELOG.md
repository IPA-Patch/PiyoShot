# Changelog

All notable changes to PiyoShot land here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is
[Semantic Versioning](https://semver.org/) independent of the target
PiyoShogi app's own version number (see [`README.md#versioning`](README.md#versioning)).

## [Unreleased]

Target: **PiyoShogi 5.7.5 (build 199)**, iOS 15.0–16.5 arm64 rootless.

### Added

- **P0 skeleton**: dylib loads, `logging_init()` fires,
  `PIYOSHOT_VERSION` + `PIYOSHOT_COMMIT` stamped on the boot line, dyld
  scan locates PiyoShogi's main image and either dispatches the JB /
  jailed installers or the binpatch bootstrap.
- **P1 hooks** (`Sources/PiyoShot/Hook_Validator.m`,
  `Hook_ParseSFEN.m`):
  - **validator @ `0x41270`** — forced to `return 1` so the batch
    runner can push any SFEN without legality rejection. The original
    validator is still invoked so its side effects (logging, etc.)
    stay live; only its return is discarded.
  - **parseSFEN @ `0x43704`** — pass-through trampoline whose only job
    is to expose the orig pointer as `piyoshot_orig_parse_sfen` so a
    later batch runner (P4) can call it directly per SFEN.
- **binpatch recipe** (`recipes/piyoshot.py`):
  - `CAVE_REGION = (0xd1c010, 0xd20000)` — 16368 B of __TEXT zero-fill
    at the tail of `__oslogstring`.
  - `HOOK_SLOT_BASE_RVA = 0xfb6500` — 2 slots packed against the tail
    of __bss (`0xfb6510 - 2 * 8`).
  - Both site prologues captured verbatim from a clean
    `assets/PiyoShogi-5.7.5.ipa`: `ff4301d1` (SUB SP, SP, #0x50) and
    `fc6fbaa9` (STP X28, X27, [SP, #-0x60]!). Both PC-independent.
- **Docs**: `docs/plans/piyoshogi_sideload_capture.md` (project plan
  P0–P7) and `docs/spec/piyoshogi_sideload_capture.md` (dylib design
  spec).

### Verified

- `python3 -m tools.patch_macho --recipe recipes.piyoshot --verify-only`
  reports both sites `OK` against a clean copy of the target IPA.
- End-to-end apply pass produces a patched binary with:
  - `B <cave>` at both sites decoding to the expected cave VAs,
  - cave payloads matching the canonical shape
    (STP LR → ADRP+LDR slot → MOVZ W9,#N → BLR → LDP LR → RET → 11×NOP
    → displaced prologue insn → B<orig+4>),
  - `LC_LOAD_DYLIB @executable_path/Frameworks/PiyoShot.dylib` added,
  - `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` set in
    Info.plist.

- **P2 overlay** (`Sources/PiyoShot/PiyoOverlay.{h,m}`,
  `PiyoSheetVC.{h,m}`):
  - Transparent `UIWindow` pinned at `UIWindowLevelAlert + 1000` on
    the foreground window scene.
  - `pointInside:withEvent:` returns YES only for the bottom-right
    100×100 pt region so every other touch flows through to
    PiyoShogi untouched.
  - `UIPanGestureRecognizer` inside the corner triggers when
    `dx > 60 && dy > 60` (bottom-right → top-left drag) and presents
    `PiyoSheetVC` on the current top view controller of the key
    window as a `UIModalPresentationPageSheet` with medium + large
    detents so the ShogiBoardView stays visible above the sheet.
  - `PiyoSheetVC` is a placeholder for now (title + version + status
    label). Real body (JSONL picker + progress + start/cancel + target
    toggle) lands with the batch runner in P3+.
  - Installer arms both `DidFinishLaunching` and `DidBecomeActive`
    observers so it survives both early and late dylib load timing.

### Not yet in

- **P3+** — JSONL picker, batch runner, PNG capture. See
  `docs/plans/piyoshogi_sideload_capture.md` for the remaining
  milestones.
