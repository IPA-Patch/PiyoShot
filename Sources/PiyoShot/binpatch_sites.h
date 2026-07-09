#pragma once

#include <stdint.h>

// ===========================================================================
// binpatch_sites.h — PiyoShot binpatch slot table.
//
// Single source of truth shared between two consumers:
//
//   * Sources/PiyoShot/ChinlanDispatcher.m — defines `gPSHookSlots[]`
//     (placed in __DATA,__bss inside the patched PiyoShogi executable),
//     publishes each hook function pointer into its slot at
//     dylib-constructor time, and caches each orig-trampoline VA into a
//     typed `static *_t orig_*` so the per-site hook functions can chain
//     back to PiyoShogi.
//
//   * recipes/piyoshot.py — parses the `PIYOSHOT_SITE_*` columns below and
//     emits one entry-cave per site (replacing the site's first 4 bytes
//     with `B <cave>`), plus an orig-trampoline tail in every cave. The
//     PIYOSHOT_SLOT_* index is loaded into W9 as the cave's `MOVZ W9, #imm`
//     operand.
//
// The header is plain C99 so it imports cleanly from both Objective-C and
// Python (the recipe mirrors the slot indices as plain constants; no
// Python build dep).
//
// VERSION PINNING
// ---------------
// Every RVA below is pinned to PiyoShogi 5.7.5 (build 199). When
// PiyoShogi updates, re-derive both this table and each Hook_*.m's RVA
// in lock-step against the new binary.
// ===========================================================================

// ---------------------------------------------------------------------------
// Slot indices. The cave's MOVZ W9 operand passes this value to the hook
// function; bodies that do not consume X9 (most of them) ignore it.
// ---------------------------------------------------------------------------
enum {
    PIYOSHOT_SLOT_VALIDATOR   = 0,   // local move-legality validator (return 1 → accept any move)
    PIYOSHOT_SLOT_PARSE_SFEN  = 1,   // parseSFEN(Position*, const char *) — kept callable for the batch runner
    PIYOSHOT_SLOT_COUNT       = 2,
};

// ---------------------------------------------------------------------------
// The 8-byte aligned slot table. Storage lives in the patched PiyoShogi
// executable's __DATA,__bss at PIYOSHOT_HOOK_SLOT_BASE_RVA — recipes/piyoshot.py
// reserves the range
//   [PIYOSHOT_HOOK_SLOT_BASE_RVA, PIYOSHOT_HOOK_SLOT_BASE_RVA + PIYOSHOT_SLOT_COUNT*8)
// and bakes each cave's ADRP+LDR pair against that VA.
//
// `gPSHookSlots` is a dylib-side pointer that ChinlanDispatcher.m
// initialises to `piyoBase + PIYOSHOT_HOOK_SLOT_BASE_RVA` at bootstrap
// time. The per-Hook `publish_*_slots()` helpers keep writing
// `gPSHookSlots[PIYOSHOT_SLOT_X] = (void *)hook_fn;` verbatim; the
// C subscript turns into a __DATA store at the same VA the cave is about
// to LDR from. CSM does not police __DATA stores, so the dylib can
// publish freely.
// ---------------------------------------------------------------------------
// PiyoShogi 5.7.5 (build 199): __bss spans RVA [0xf52540, 0xfb6510).
// 2 slots * 8 B packed against the tail → base = 0xfb6510 - 16 = 0xfb6500.
// MUST equal recipes/piyoshot.py::HOOK_SLOT_BASE_RVA.
#define PIYOSHOT_HOOK_SLOT_BASE_RVA 0xfb6500
extern void **gPSHookSlots;

// ---------------------------------------------------------------------------
// Cave payload size.
//
// MUST match `recipes/piyoshot.py::CAVE_PAYLOAD_SIZE`. The last 8 bytes
// of every cave hold the orig-trampoline (displaced prologue insn + B
// <site+4>); PSResolveOrigTrampoline() derives the trampoline
// VA as `cave_va + PIYOSHOT_BINPATCH_CAVE_PAYLOAD_SIZE - 8`.
// ---------------------------------------------------------------------------
#define PIYOSHOT_BINPATCH_CAVE_PAYLOAD_SIZE 84

// ---------------------------------------------------------------------------
// Orig-trampoline resolver.
//
// Reads the `B <cave_va>` written at `piyoBase + siteRVA` by the patcher,
// decodes the imm26 to recover cave_va, and returns
// `cave_va + PIYOSHOT_BINPATCH_CAVE_PAYLOAD_SIZE - 8` — i.e. the address
// of the cave's orig-trampoline tail. Each per-site `publish_*_slots()`
// casts the result to its typed `*_t` and assigns it to the existing
// `static *_t orig_*` so the hook body's chain-back path keeps working
// unchanged.
//
// Returns 0 on failure; callers should log and leave orig NULL.
// ---------------------------------------------------------------------------
uintptr_t PSResolveOrigTrampoline(uintptr_t piyoBase, uintptr_t siteRVA);

// ---------------------------------------------------------------------------
// Site RVAs (relative to PiyoShogi's mach_header). Used by:
//
//   * the dylib, to recover each `static *_t orig_*` via
//     PSResolveOrigTrampoline(piyoBase, PIYOSHOT_SITE_RVA_*).
//
//   * recipes/piyoshot.py — both as the patch site addresses and as
//     the orig-trampoline endpoint (orig trampoline returns to site+4).
//
// Pinned to PiyoShogi 5.7.5 (build 199).
// ---------------------------------------------------------------------------
#define PIYOSHOT_SITE_RVA_VALIDATOR   0x41270
#define PIYOSHOT_SITE_RVA_PARSE_SFEN  0x43704

// ---------------------------------------------------------------------------
// Data slot (not a hook site). Reads as `Position**` — deref once to get
// PiyoShogi's active Position pointer. NULL when PiyoShogi hasn't
// initialised its board VC yet; the batch runner errors out with a
// "open a game first" prompt in that case (spec §6.3 auto-bootstrap via
// URL scheme is deferred — §10 forbids adding a scheme).
//
// Pinned to PiyoShogi 5.7.5 (build 199) alongside the hook sites above.
// ---------------------------------------------------------------------------
#define PIYOSHOT_POSITION_SLOT_RVA    0xf505d8
