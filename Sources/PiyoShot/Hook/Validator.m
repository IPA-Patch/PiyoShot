#import "Internal.h"

// ===========================================================================
// Hook_Validator — force PiyoShogi's local move-legality validator to
// always return 1.
//
// Site: 0x41270 in PiyoShogi 5.7.5 (build 199).
// Prologue: SUB SP, SP, #0x50 (`ff 43 01 d1`, PC-independent).
//
// PiyoShogi calls this validator before applying any incoming
// SFEN/Position update. Any legality check that would refuse a hand-
// crafted position is short-circuited here so the batch runner can push
// arbitrary SFENs through parseSFEN without them getting rejected on
// the way in. See docs/plans/piyoshogi_sideload_capture.md §5 (P1) for
// the success criterion (non-legal SFEN reflected in the ShogiBoardView).
//
// The hook is a pure return-1 replacement; the original validator is
// still invoked for its logging / side-effect value, but its return is
// discarded. Signature is the arm64 argument-register-wide default
// (X0..X7 as uint64_t) so the compiler does not touch registers the
// caller might rely on being live.
// ===========================================================================

typedef uint64_t (*validator_fn)(uint64_t, uint64_t, uint64_t, uint64_t,
                                  uint64_t, uint64_t, uint64_t, uint64_t);
static validator_fn orig_validator = NULL;

static uint64_t hookValidator(uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3,
                                uint64_t a4, uint64_t a5, uint64_t a6, uint64_t a7) {
    if (orig_validator) {
        (void)orig_validator(a0, a1, a2, a3, a4, a5, a6, a7);
    }
    return 1;
}

#if IPA_CHINLAN

void PSPublishValidatorSlots(uintptr_t piyoBase) {
    orig_validator = (validator_fn)PSResolveOrigTrampoline(
        piyoBase, PIYOSHOT_SITE_RVA_VALIDATOR);
    gPSHookSlots[PIYOSHOT_SLOT_VALIDATOR] = (void *)hookValidator;
    IPALog([NSString stringWithFormat:
              @"[validator] slot=%p orig=%p (RVA 0x%X)",
              (void *)hookValidator,
              (void *)orig_validator,
              PIYOSHOT_SITE_RVA_VALIDATOR]);
}

#else

#define RVA_VALIDATOR 0x41270

void PSInstallValidatorHook(uintptr_t piyoBase) {
    void *site = (void *)(piyoBase + RVA_VALIDATOR);
    MSHookFunction(site, (void *)hookValidator, (void **)&orig_validator);
    IPALog([NSString stringWithFormat:
              @"[validator] hooked @0x%lx orig=%p",
              (unsigned long)site, (void *)orig_validator]);
}

#endif  // IPA_CHINLAN
