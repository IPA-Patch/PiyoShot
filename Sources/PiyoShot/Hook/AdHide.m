#import "Internal.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ===========================================================================
// Hook_AdHide — direct ObjC-runtime port of
// scripts/dist/hook_piyoshogi_adkill.js (which was the original Frida
// script tkgstrator used against PiyoShogi's mediated ad stack).
//
// Three layers, in order of effectiveness:
//
//   1. -[UIView addSubview:] swizzle. Every ad SDK ultimately hangs its
//      banner off a UIView somewhere; we intercept every add and, if
//      the child's class name matches the ad prefix set, force hidden
//      + alpha=0 immediately after orig runs. Cheap, catches every
//      SDK we've seen ship with PiyoShogi.
//
//   2. NoOp on the Google / Meta load methods. Prevents the network
//      fetch + animation setup entirely for those SDKs (D3-mediated
//      ADG will still fill via other stacks, hence layer 1 as a net).
//
//   3. Retroactive sweep 500 ms after -DidFinishLaunching. Walks every
//      window's view hierarchy once and hides any ad-classed view that
//      was already added before the addSubview: swizzle went in.
//
// Runtime-only ObjC — safe on both JB (Substrate + rootless) and
// CHINLAN (statically-patched IPA), because it only writes to __DATA
// method tables which CSM does not police. No new binpatch slot.
// ===========================================================================

// ---------------------------------------------------------------------------
// Ad-class detection
// ---------------------------------------------------------------------------

// Prefixes copied verbatim from adkill.js' addSubview: regex.
// GAD / ADG / FBAd / FBInterstitial / FAD (FiveAd) / PAG (Pangle) /
// VungleAd / BUAd (ByteDance).
static BOOL isAdClassName(NSString *name) {
    if (name.length == 0) return NO;
    static NSArray<NSString *> *prefixes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        prefixes = @[
            @"GAD",
            @"ADG",
            @"FBAd",
            @"FBInterstitial",
            @"FAD",
            @"PAG",
            @"VungleAd",
            @"BUAd",
        ];
    });
    for (NSString *p in prefixes) {
        if ([name hasPrefix:p]) return YES;
    }
    return NO;
}

static void hideView(UIView *v) {
    if (!v) return;
    v.hidden = YES;
    v.alpha  = 0.0;
}

// ---------------------------------------------------------------------------
// Layer 1: -[UIView addSubview:] swizzle
// ---------------------------------------------------------------------------

typedef void (*addSubview_imp_t)(id, SEL, UIView *);
static addSubview_imp_t orig_addSubview = NULL;

static void hookAddSubview(id self, SEL _cmd, UIView *sub) {
    // Call orig FIRST so the view is actually parented before we mutate
    // its state — some SDKs assert their view has a superview during
    // internal setup callbacks fired synchronously from addSubview:.
    if (orig_addSubview) orig_addSubview(self, _cmd, sub);
    if (sub && isAdClassName(NSStringFromClass([sub class]))) {
        hideView(sub);
    }
}

// ---------------------------------------------------------------------------
// Layer 2: NoOp specific ad-SDK load methods.
// ---------------------------------------------------------------------------

static void noopV(id self, SEL _cmd, ...) {
    // deliberately empty
}

static void swizzleToNoop(NSString *className, NSString *selName) {
    Class cls = NSClassFromString(className);
    if (!cls) return;
    SEL sel = NSSelectorFromString(selName);
    // Try instance method first, fall back to class method.
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) m = class_getClassMethod(cls, sel);
    if (!m) return;
    method_setImplementation(m, (IMP)noopV);
    IPALog([NSString stringWithFormat:
              @"[adhide] noop  %@ %@", className, selName]);
}

// ---------------------------------------------------------------------------
// Layer 3: retroactive sweep over live view hierarchies.
// ---------------------------------------------------------------------------

static void sweepHide(UIView *root) {
    if (!root) return;
    if (isAdClassName(NSStringFromClass(root.class))) {
        hideView(root);
    }
    for (UIView *sub in root.subviews) {
        sweepHide(sub);
    }
}

static void retroactiveSweep(void) {
    NSUInteger hidden = 0;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            NSUInteger before = hidden;
            sweepHide(w);
            (void)before; // (counter kept for future logging if we want it)
        }
    }
    IPALog(@"[adhide] retroactive sweep done");
}

// ---------------------------------------------------------------------------
// Installer — fires on DidFinishLaunching so UIKit + SDK classes are up.
// ---------------------------------------------------------------------------

static void installNow(void) {
    // (1) UIView addSubview: swizzle
    Method m = class_getInstanceMethod(UIView.class, @selector(addSubview:));
    if (m && !orig_addSubview) {
        orig_addSubview = (addSubview_imp_t)method_getImplementation(m);
        method_setImplementation(m, (IMP)hookAddSubview);
        IPALog(@"[adhide] swizzled -[UIView addSubview:]");
    }

    // (2) NoOp Google / Meta load methods (matching adkill.js payload).
    swizzleToNoop(@"GADBannerView",     @"loadRequest:");
    swizzleToNoop(@"GADInterstitial",   @"loadRequest:");
    swizzleToNoop(@"GADInterstitialAd", @"loadWithAdUnitID:request:completionHandler:");
    swizzleToNoop(@"GADRewardedAd",     @"loadWithAdUnitID:request:completionHandler:");
    swizzleToNoop(@"FBAdView",          @"loadAd");
    swizzleToNoop(@"FBInterstitialAd",  @"loadAd");

    // (3) Retroactive sweep after 500 ms — matches the Frida script's
    // setTimeout so any banner attached before the swizzle went in
    // still ends up hidden.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(),
                   ^{ retroactiveSweep(); });
}

void PSInstallAdHideHook(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification * _Nonnull note) {
            installNow();
        }];
    });
}
