#pragma once

#import <Foundation/Foundation.h>
#import <stdint.h>

// ---------------------------------------------------------------------------
// Hook engine selection — delegated to Sources/Chinlan/hookengine.h.
//
// JB / rootless builds (default): MobileSubstrate's MSHookFunction.
// Jailed (sideload) builds: Dobby, statically linked. Selected at compile
// time via -DIPA_JAILED=1 in the Makefile.
//
// In IPA_CHINLAN mode the Hook_*.m files never invoke MSHookFunction —
// they only define hook function bodies and `publish_*_slots(base)`
// helpers — so neither substrate nor Dobby need to be in scope.
// ---------------------------------------------------------------------------
#if !IPA_CHINLAN
#import "hookengine.h"
#endif

// binpatch_sites.h is the single source of truth for every version-pinned
// PiyoShogi RVA (hook sites + data slots like Position). Both JB and
// binpatch builds read those constants, so include unconditionally —
// the binpatch-only externs it declares (gPSHookSlots,
// PSResolveOrigTrampoline) stay unresolved without harm as long
// as nothing under the JB build references them.
#import "binpatch_sites.h"

// File-log API. Implementation in Sources/Chinlan/logging.m; Tweak.m
// passes the os_log subsystem string to IPALoggingInit() at constructor
// time.
#import "logging.h"

// ===========================================================================
// Internal.h — PiyoShot shared declarations.
//
// STATUS: P0 skeleton. The build produces a loadable dylib that logs its
// version + commit on constructor. Actual hook installers (validator,
// parseSFEN) and the overlay UI / batch runner / capture layer are
// tracked as P1–P7 in docs/plans/piyoshogi_sideload_capture.md and
// docs/spec/piyoshogi_sideload_capture.md.
// ===========================================================================

#ifndef PIYOSHOT_COMMIT
#define PIYOSHOT_COMMIT "unknown"
#endif

// SemVer string, baked at compile time by the Makefile.
// Format: `vMAJOR.MINOR.PATCH` on a tag, `vX.Y.Z-N-gHASH[-dirty]` between
// tags, the short HEAD when no tag has been cut yet, or "dev" outside a
// git repo. Surfaced in the boot log and on the in-app About row so a
// sideloaded copy is always self-identifying.
#ifndef PIYOSHOT_VERSION
#define PIYOSHOT_VERSION "dev"
#endif

// ---------------------------------------------------------------------------
// Per-module hook installers. Each takes the PiyoShogi mach_header base
// address and installs its RVA hook via MSHookFunction / DobbyHook.
//
// In IPA_CHINLAN mode PiyoShogi has already been statically rewritten
// to route each site into a __TEXT cave that BLR's gPSHookSlots[N],
// so the installer is replaced by publish_*_slots() which writes the
// per-site hook function pointer into the slot table (a __DATA store
// CSM does not police) and caches the orig-trampoline VA off the cave.
// ---------------------------------------------------------------------------
#if IPA_CHINLAN
void PSPublishValidatorSlots(uintptr_t piyoBase);
void PSPublishParseSFENSlots(uintptr_t piyoBase);
#else
void PSInstallValidatorHook(uintptr_t piyoBase);
void PSInstallParseSFENHook(uintptr_t piyoBase);
#endif

// ---------------------------------------------------------------------------
// parseSFEN chain-back. Batch runner (P4+) calls this once per SFEN via
// the trampoline the hook installer captured. NULL until the installer
// has run — callers must NULL-guard.
//   pos   : Position pointer (read from PiyoShogi's Position slot @
//           base + 0xf505d8). Passing NULL crashes on first entry
//           because parseSFEN dereferences it — bootstrap the main view
//           via the URL scheme first (see spec §6.3).
//   sfen  : NUL-terminated SFEN string. UTF-8.
//   ret   : 1 on success, 0 on parse error.
// ---------------------------------------------------------------------------
typedef int32_t (*PSParseSFENFn)(void *pos, const char *sfen);
extern PSParseSFENFn PSOrigParseSFEN;

// Return value of the most recent parseSFEN invocation the hook body
// witnessed, updated inside hookParseSFEN after the orig call. The
// batch runner resets this to -1 before invoking the paste selector and
// checks it after the wait — anything other than 1 means the SFEN was
// rejected and that record should be skipped without snapshotting.
extern int32_t PSLastParseSFENRet;

// Callback fired on the main queue after every parseSFEN return. The
// batch runner installs this before invoking the paste selector so it
// can trigger the snapshot as soon as the 3rd parseSFEN (final redraw)
// completes — no more fixed dispatch_after guessing.
//
// Set to NULL when no one is listening; the hook checks before
// dispatching. Only main-queue-safe operations belong in the callback
// because the hook re-hops onto main before firing it.
// The callback is nil when no one is listening. We deliberately do NOT
// use an explicit _Nullable annotation here — introducing any nullability
// specifier turns on -Wnullability-completeness for every file that
// pulls in Internal.h, which trips on the other unannotated pointers
// (PSParseSFENFn, PSCurrentPosition) that the rest of
// the codebase already treats as unspecified.
typedef void (^PSParseSFENCallbackBlock)(int32_t ret);
extern PSParseSFENCallbackBlock PSParseSFENCallback;

// ---------------------------------------------------------------------------
// PiyoShogi mach_header base address, captured once the image is mapped.
// Zero until Tweak.m's dyld scan (or the binpatch bootstrap) has run;
// callers reading Position slot or other RVAs must NULL-guard.
// ---------------------------------------------------------------------------
extern uintptr_t PSPiyoShogiBase;

// ---------------------------------------------------------------------------
// Current Position pointer. Reads the Position slot at
// PSPiyoShogiBase + PIYOSHOT_POSITION_SLOT_RVA and derefs it once.
// Returns NULL when the base isn't captured yet or when PiyoShogi hasn't
// initialised its board VC — the batch runner surfaces that as an
// "open a game first" prompt.
// ---------------------------------------------------------------------------
void *PSCurrentPosition(void);

// Runtime ObjC swizzle that pins every ad-banner UIView subclass to
// hidden = YES and skips its -layoutSubviews (where the SDKs run
// pulsating / fade animations that flatten the batch runner's per-
// record wall clock). Flavor-agnostic — no binpatch slot required.
void PSInstallAdHideHook(void);

// Runtime ObjC swizzle that NoOps -[AVAudioPlayer play] so PiyoShogi's
// piece-move / paste-success SE never spins up an AudioQueue during a
// batch. At the runner's ~143 ms/record cadence the audio subsystem's
// per-process AudioQueue ceiling is otherwise hit at ~4841 iterations,
// which surfaces as an unhandled NSException inside
// -[UINib instantiateWithOwner:options:] when the next nib load
// touches the poisoned audio session. Flavor-agnostic.
void PSInstallSoundKillHook(void);
