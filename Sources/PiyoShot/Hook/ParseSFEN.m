#import "Internal.h"

// ===========================================================================
// Hook_ParseSFEN — pass-through hook whose only job is to expose
// parseSFEN as a callable function pointer for the batch runner.
//
// Site: 0x43704 in PiyoShogi 5.7.5 (build 199).
// Prologue: STP X28, X27, [SP, #-0x60]! (`fc 6f ba a9`, PC-independent).
//
// parseSFEN is a Swift internal symbol we cannot resolve with dlsym.
// The hook trampoline is the vehicle for keeping the orig pointer
// around: whether we go through Dobby (JB/jailed) or the cave's tail
// (binpatch), the `orig_parse_sfen` handle we cache here is what the
// batch runner in a later phase calls to drive one SFEN at a time.
//
// The hook body itself is a pure pass-through. If PiyoShogi calls
// parseSFEN of its own accord we do not want to alter the outcome —
// only the fact that we hold the orig pointer matters.
// ===========================================================================

// Definition matching the extern in Internal.h. NULL until publisher /
// installer has run.
PSParseSFENFn PSOrigParseSFEN = NULL;

// Latest orig return; -1 means "not observed since last reset".
int32_t PSLastParseSFENRet = -1;

// Optional listener installed by the batch runner. Fires on the main
// queue after every orig call so the runner can drive the snapshot on
// completion instead of a fixed delay.
PSParseSFENCallbackBlock PSParseSFENCallback = NULL;

// Walk the fp chain manually and return the LR at `depth` (0 = our LR,
// same as __builtin_return_address(0); 1 = caller's LR; 2 = caller's
// caller's LR; ...). Stops if fp becomes NULL or unaligned — better than
// __builtin_return_address(N>0) which the ARM64 backend doesn't reliably
// synthesise across arbitrary depths.
static void *walkLR(int depth) {
    void **fp = (void **)__builtin_frame_address(0);
    for (int i = 0; i <= depth; i++) {
        if (!fp || ((uintptr_t)fp & 0x7)) return NULL;
        if (i == depth) return fp[1];   // fp[0] = saved fp, fp[1] = saved lr
        fp = (void **)fp[0];
    }
    return NULL;
}

static int32_t hookParseSFEN(void *pos, const char *sfen) {
    // Diagnostic frame-walk / per-call ret logging was removed once the
    // paste-clipboard driver was proven — three of these fire per
    // record and the noise was drowning the batch-progress lines. Only
    // parse failures (ret != 1) still emit a line below.
    if (!PSOrigParseSFEN) return 0;
    int32_t ret = PSOrigParseSFEN(pos, sfen);
    PSLastParseSFENRet = ret;
    if (ret != 1) {
        IPALog([NSString stringWithFormat:
                  @"[parseSFEN] rejected ret=%d sfen=\"%s\"",
                  (int)ret, sfen ?: "(null)"]);
    }
    // Snapshot the block pointer BEFORE hopping — the runner may
    // reassign the global while our dispatched invocation is in flight;
    // grabbing a local copy pins the block we saw firing.
    PSParseSFENCallbackBlock cb = PSParseSFENCallback;
    if (cb) {
        dispatch_async(dispatch_get_main_queue(), ^{
            cb(ret);
        });
    }
    return ret;
}

#if IPA_CHINLAN

void PSPublishParseSFENSlots(uintptr_t piyoBase) {
    PSOrigParseSFEN = (PSParseSFENFn)
        PSResolveOrigTrampoline(piyoBase, PIYOSHOT_SITE_RVA_PARSE_SFEN);
    gPSHookSlots[PIYOSHOT_SLOT_PARSE_SFEN] = (void *)hookParseSFEN;
    IPALog([NSString stringWithFormat:
              @"[parseSFEN] slot=%p orig=%p (RVA 0x%X)",
              (void *)hookParseSFEN,
              (void *)PSOrigParseSFEN,
              PIYOSHOT_SITE_RVA_PARSE_SFEN]);
}

#else

#define RVA_PARSE_SFEN 0x43704

void PSInstallParseSFENHook(uintptr_t piyoBase) {
    void *site = (void *)(piyoBase + RVA_PARSE_SFEN);
    MSHookFunction(site, (void *)hookParseSFEN,
                   (void **)&PSOrigParseSFEN);
    IPALog([NSString stringWithFormat:
              @"[parseSFEN] hooked @0x%lx orig=%p",
              (unsigned long)site, (void *)PSOrigParseSFEN]);
}

#endif  // IPA_CHINLAN
