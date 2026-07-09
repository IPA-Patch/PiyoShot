#import "Internal.h"

#if IPA_CHINLAN

#import "chinlan.h"   // Sources/Chinlan — ipa_binpatch_{find_image,resolve_orig}
#include <stdint.h>

// ===========================================================================
// ChinlanDispatcher.m — PiyoShot-local glue for the IPA_CHINLAN build.
//
// The generic parts (image lookup + B<cave> decode → orig trampoline)
// live in Sources/Chinlan/binpatch.{h,m}. This file only owns what is
// genuinely PiyoShot-specific:
//
//   1. `gPSHookSlots` — the __DATA,__bss table pointer the patched
//      PiyoShogi executable's caves call into. recipes/piyoshot.py's
//      HOOK_SLOT_BASE_RVA targets exactly this slot range; the patcher
//      resolves its VA from the target binary and bakes ADRP+LDR pairs
//      against it. Slot count is the PIYOSHOT_SLOT_* enum in
//      binpatch_sites.h.
//
//   2. `PSResolveOrigTrampoline()` — a thin wrapper over
//      IPAChinlanResolveOrig() that pins
//      PIYOSHOT_BINPATCH_CAVE_PAYLOAD_SIZE so each per-site publisher
//      doesn't have to thread the payload size through every call site.
//
//   3. `PSChinlanBootstrap()` — the dyld-image-found callback
//      that runs every publish_*_slots() in installer-order. Tweak.m's
//      constructor + retry timer call it; the bootstrap is idempotent,
//      so re-running after a successful publish is a NOP.
//
// STATUS: P0 skeleton. publish_all() below has no per-slot publishers
// yet — the bootstrap just points gPSHookSlots at the reserved
// __bss range and logs. Actual publishers (validator + parseSFEN) land
// in P1.
// ===========================================================================

// ---------------------------------------------------------------------------
// (1) Slot table pointer. The actual PIYOSHOT_SLOT_COUNT * 8 B of
// storage live in PiyoShogi's __DATA,__bss at PIYOSHOT_HOOK_SLOT_BASE_RVA;
// this dylib-side variable is the base pointer per-site
// `publish_*_slots()` helpers index through.
// ---------------------------------------------------------------------------

void **gPSHookSlots = NULL;

// ---------------------------------------------------------------------------
// (2) Thin wrapper that pins this tweak's cave payload size.
// ---------------------------------------------------------------------------

uintptr_t PSResolveOrigTrampoline(uintptr_t piyoBase, uintptr_t siteRVA) {
    return IPAChinlanResolveOrig(piyoBase, siteRVA,
                                     PIYOSHOT_BINPATCH_CAVE_PAYLOAD_SIZE);
}

// ---------------------------------------------------------------------------
// (3) Bootstrap shared with Tweak.m. Looks up PiyoShogi via Common's
// IPAChinlanFindImage(), then runs every publish_*_slots() in
// installer-order. Writing into gPSHookSlots[] is a __DATA store
// (CSM-safe) and is idempotent.
// ---------------------------------------------------------------------------

static BOOL g_piyoshot_binpatch_published = NO;

static void publish_all(uintptr_t piyoBase) {
    // Aim the slot pointer at PiyoShogi's __bss BEFORE any per-site
    // publisher writes into it. Recipe constants and this RVA are pinned
    // together — if you change either, change both.
    gPSHookSlots = (void **)(piyoBase + PIYOSHOT_HOOK_SLOT_BASE_RVA);
    IPALog([NSString stringWithFormat:
              @"[binpatch] slot base=%p (piyoBase+0x%X)",
              (void *)gPSHookSlots, PIYOSHOT_HOOK_SLOT_BASE_RVA]);

    PSPublishValidatorSlots(piyoBase);
    PSPublishParseSFENSlots(piyoBase);
}

void PSChinlanBootstrap(void) {
    if (g_piyoshot_binpatch_published) return;

    uintptr_t piyoBase = IPAChinlanFindImage("/PiyoShogi.app/PiyoShogi");
    if (piyoBase == 0) return;  // not mapped yet; caller retries

    IPALog([NSString stringWithFormat:
              @"[binpatch] PiyoShogi base=0x%lx",
              (unsigned long)piyoBase]);
    PSPiyoShogiBase = piyoBase;

    publish_all(piyoBase);
    g_piyoshot_binpatch_published = YES;
    IPALog(@"[binpatch] === all slots published ===");
}

BOOL PSChinlanPublished(void) {
    return g_piyoshot_binpatch_published;
}

#endif  // IPA_CHINLAN
