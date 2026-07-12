#import "Internal.h"
#import "PiyoOverlay.h"
#import <mach-o/dyld.h>
#import <string.h>

// PiyoShogi mach_header base, published once by whichever bootstrap path
// (JB dyld scan or binpatch image lookup) resolves the image first. Read
// by PSCurrentPosition() below and by the batch runner (P4+) for
// any other RVA it needs.
uintptr_t PSPiyoShogiBase = 0;

void *PSCurrentPosition(void) {
    if (PSPiyoShogiBase == 0) return NULL;
    void **slot = (void **)(PSPiyoShogiBase + PIYOSHOT_POSITION_SLOT_RVA);
    return *slot;
}

// ===========================================================================
// PiyoShot — entry point.
//
// STATUS: P0 skeleton. Loads into PiyoShogi, initialises the file log
// (mirrored to NSLog + os_log), stamps the boot line with build version
// + commit, and either kicks the binpatch bootstrap (which currently
// only publishes the slot pointer — no per-site publishers yet) or
// logs which JB / jailed installer path was chosen.
//
// Real hook installers land in P1 (validator + parseSFEN → Dobby /
// substrate on JB / jailed; publish_*_slots in binpatch mode). The
// Overlay UIWindow + corner swipe + Sheet + Batch Runner + Capture
// layers are P2 onwards — see docs/plans/piyoshogi_sideload_capture.md.
// ===========================================================================

#if IPA_CHINLAN

// Forward decl (defined in ChinlanDispatcher.m).
void PSChinlanBootstrap(void);
BOOL PSChinlanPublished(void);

// Binpatch bootstrap — delegate to ChinlanDispatcher.m. The dyld scan +
// publish fan-out is idempotent, so we just spin the retry timer until
// PSChinlanPublished() flips true.
static void tryBootstrap(void) {
    if (!PSChinlanPublished()) PSChinlanBootstrap();

    if (!PSChinlanPublished()) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            tryBootstrap();
        });
    }
}

#else  // !IPA_CHINLAN

static BOOL g_piyoHooked = NO;

// P0 skeleton: locate the PiyoShogi main image so P1's install_*_hook
// helpers have somewhere to hang off of. Actual MSHookFunction /
// DobbyHook calls land in P1.
static void installPiyoHooks(void) {
    if (g_piyoHooked) return;

    uint32_t imgCount = _dyld_image_count();
    uintptr_t piyoBase = 0;
    const char *piyoName = NULL;
    for (uint32_t i = 0; i < imgCount; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "/PiyoShogi.app/PiyoShogi")) {
            piyoBase = (uintptr_t)_dyld_get_image_header(i);
            piyoName = name;
            break;
        }
    }

    if (piyoBase == 0) {
        // Not loaded yet - retry will call us again.
        return;
    }

    IPALog([NSString stringWithFormat:
              @"PiyoShogi base=0x%lx (%s)",
              (unsigned long)piyoBase, piyoName ? piyoName : "?"]);
    PSPiyoShogiBase = piyoBase;

    PSInstallValidatorHook(piyoBase);
    PSInstallParseSFENHook(piyoBase);

    g_piyoHooked = YES;
    IPALog(@"=== PiyoShogi hooks installed ===");
}

static void retryInstallHooks(void) {
    if (!g_piyoHooked) installPiyoHooks();

    if (!g_piyoHooked) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            retryInstallHooks();
        });
    }
}

#endif  // IPA_CHINLAN

__attribute__((constructor)) static void init(void) {
    // Common's IPALoggingInit takes the os_log subsystem string; it
    // derives the short tag ("piyoshot") + sandbox log basename from
    // the last dot-separated segment, so a Documents/<sandbox>/piyoshot.log
    // path surfaces under Files.app once the IPA carries
    // UIFileSharingEnabled (the binpatch pipeline writes both Info.plist
    // keys via recipes/piyoshot.py::PLIST_KEYS).
    IPALoggingInit("net.studioki.PiyoShogi.piyoshot");
    IPALog([NSString stringWithFormat:
              @"=== PiyoShot %s (%s) loaded ===",
              PIYOSHOT_VERSION, PIYOSHOT_COMMIT]);

    // PiyoShogi's main image is almost certainly not mapped at
    // constructor time; retry from a background queue until it is.
#if IPA_CHINLAN
    tryBootstrap();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        tryBootstrap();
    });
#else
    installPiyoHooks();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        retryInstallHooks();
    });
#endif

    // Ad-banner hide swizzle — pure ObjC runtime, so it lands the same
    // way across JB / CHINLAN / jailed builds. Skips the ad SDKs'
    // -layoutSubviews (where the pulsating / fade animations run) which
    // was eating a big chunk of the per-record wall clock in the
    // batch runner.
    PSInstallAdHideHook();

    // Sound-kill swizzle — NoOps -[AVAudioPlayer play] so PiyoShogi's
    // per-paste SE never spins up an AudioQueue. At the batch runner's
    // ~143 ms/record cadence the per-process AudioQueue ceiling was
    // otherwise being hit around iteration 4841, which surfaces as an
    // unhandled NSException inside -[UINib instantiateWithOwner:options:].
    PSInstallSoundKillHook();

    // P2: transparent UIWindow + corner-swipe recogniser. The installer
    // arms UIApplicationDidFinishLaunching / DidBecomeActive observers
    // and builds the window as soon as UIKit is alive.
    PSOverlayInstall();

    IPALog(@"=== PiyoShot constructor done ===");
}
