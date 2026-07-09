#import "PiyoOverlay.h"
#import "PiyoSheetVC.h"
#import "Internal.h"

#import <UIKit/UIKit.h>

// ===========================================================================
// Right-edge hit-test window. pointInside:withEvent: returns YES only for
// a thin strip along the right edge — every other touch flows through to
// PiyoShogi. That is what lets the overlay sit at UIWindowLevelAlert
// + 1000 without stealing input.
//
// bounds MUST be non-zero for this to work: an overlay UIWindow
// constructed with -initWithWindowScene: on iOS 15+ does not inherit
// the scene's frame automatically, so PiyoOverlayController below sets
// window.frame + rootVC.view.frame explicitly and pins the
// autoresizingMask so rotation / split-view resize stays in sync.
// ===========================================================================

static const CGFloat kEdgeWidth    = 30.0;    // right-edge hit-test strip width in pt
static const CGFloat kTriggerDelta = 80.0;    // required leftward drag distance in pt

@interface PiyoOverlayWindow : UIWindow
@end

@implementation PiyoOverlayWindow

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    CGRect edge = CGRectMake(self.bounds.size.width - kEdgeWidth,
                             0,
                             kEdgeWidth,
                             self.bounds.size.height);
    return CGRectContainsPoint(edge, point);
}

@end

// Rotation / split-view resize: UIWindow constructed with
// -initWithWindowScene: does not auto-track the scene's bounds once we
// pin its frame explicitly. Overriding viewWillTransitionToSize on the
// rootVC is the iOS 13+ replacement for the deprecated
// UIApplicationDidChangeStatusBarOrientationNotification path.
@interface PiyoOverlayRootVC : UIViewController
@property (nonatomic, weak) UIWindow *managedWindow;
@end

@implementation PiyoOverlayRootVC
- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    UIWindow *w = self.managedWindow;
    if (w.windowScene) w.frame = w.windowScene.coordinateSpace.bounds;
}
@end

// ===========================================================================
// Right-edge swipe detector. Watches for a right-edge → left drag
// (start inside the right-edge strip, dx > kTriggerDelta) and presents
// PiyoSheetVC when it lands. Same gesture family as KiouForge et al.
// ===========================================================================

@interface PiyoOverlayController : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, strong) PiyoOverlayWindow *window;
@property (nonatomic, strong) UILabel           *progressBanner; // XXXX/1000 during batch
@property (nonatomic, assign) CGPoint            startPoint;
@property (nonatomic, weak)   PiyoSheetVC       *currentSheet;   // weak → auto-nil on dismiss
@end

@implementation PiyoOverlayController

+ (instancetype)shared {
    static PiyoOverlayController *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[PiyoOverlayController alloc] init]; });
    return inst;
}

- (UIWindowScene *)findActiveScene {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene *)scene;
        }
    }
    // Fallback: any window scene we can find, even not-yet-active. The
    // gesture won't fire until PiyoShogi's own window is up anyway.
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) return (UIWindowScene *)scene;
    }
    return nil;
}

- (void)buildWindow {
    if (self.window) return;

    UIWindowScene *scene = [self findActiveScene];
    if (!scene) {
        // Retry — scene not up yet.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self buildWindow]; });
        return;
    }

    // Ensure UIWindow / rootVC.view both have the scene's bounds. Without
    // this, -initWithWindowScene: leaves w.frame at (0,0,0,0) and every
    // pointInside hit-test returns NO — the exact symptom of the edge
    // swipe never firing.
    CGRect sceneBounds = scene.coordinateSpace.bounds;

    PiyoOverlayWindow *w = [[PiyoOverlayWindow alloc] initWithWindowScene:scene];
    w.frame = sceneBounds;
    w.backgroundColor = UIColor.clearColor;
    w.windowLevel = UIWindowLevelAlert + 1000;
    w.userInteractionEnabled = YES;
    // Not keyed on purpose: `hidden = NO` shows the window without
    // stealing keyWindow from PiyoShogi's own window. -makeKeyAndVisible
    // would swap keyness, which breaks first responder handling.

    PiyoOverlayRootVC *rootVC = [[PiyoOverlayRootVC alloc] init];
    rootVC.managedWindow = w;
    rootVC.view.frame = sceneBounds;
    rootVC.view.backgroundColor = UIColor.clearColor;
    rootVC.view.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    w.rootViewController = rootVC;

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    pan.delegate = self;
    pan.minimumNumberOfTouches = 1;
    pan.maximumNumberOfTouches = 1;
    [rootVC.view addGestureRecognizer:pan];

    // Progress banner — hidden until PiyoBatchRunner announces a batch.
    // Pinned to the bottom-centre safe area so the "X/N · 残 …" readout
    // is glanceable without overlapping the app's own controls.
    UILabel *progress = [[UILabel alloc] init];
    progress.font = [UIFont monospacedDigitSystemFontOfSize:14
                                                    weight:UIFontWeightSemibold];
    progress.textColor = [UIColor colorWithWhite:1.0 alpha:0.92];
    progress.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    progress.textAlignment = NSTextAlignmentCenter;
    progress.layer.cornerRadius = 6.0;
    progress.layer.masksToBounds = YES;
    progress.userInteractionEnabled = NO;
    progress.translatesAutoresizingMaskIntoConstraints = NO;
    progress.hidden = YES;
    [rootVC.view addSubview:progress];
    [NSLayoutConstraint activateConstraints:@[
        [progress.centerXAnchor constraintEqualToAnchor:rootVC.view.centerXAnchor],
        [progress.bottomAnchor  constraintEqualToAnchor:rootVC.view.safeAreaLayoutGuide.bottomAnchor
                                              constant:-6],
        [progress.heightAnchor  constraintGreaterThanOrEqualToConstant:26],
        [progress.widthAnchor   constraintGreaterThanOrEqualToConstant:120],
    ]];
    self.progressBanner = progress;

    w.hidden = NO;
    self.window = w;

    IPALog([NSString stringWithFormat:
              @"[overlay] window built  scene=%@ frame=%@ edge=%.0f@R",
              scene,
              NSStringFromCGRect(w.frame),
              kEdgeWidth]);
}

- (void)handlePan:(UIPanGestureRecognizer *)gr {
    switch (gr.state) {
        case UIGestureRecognizerStateBegan:
            self.startPoint = [gr locationInView:gr.view];
            IPALog([NSString stringWithFormat:
                      @"[overlay] pan began @(%.0f,%.0f)  view=%@",
                      self.startPoint.x, self.startPoint.y,
                      NSStringFromCGRect(gr.view.bounds)]);
            break;
        case UIGestureRecognizerStateChanged: {
            if (self.currentSheet) return;
            CGPoint p = [gr locationInView:gr.view];
            CGFloat dx = self.startPoint.x - p.x;   // moved leftward
            if (dx > kTriggerDelta) {
                IPALog([NSString stringWithFormat:
                          @"[overlay] triggered dx=%.0f", dx]);
                [self presentSheet];
            }
            break;
        }
        default:
            break;
    }
}

- (UIViewController *)topViewControllerFrom:(UIViewController *)root {
    UIViewController *cur = root;
    while (cur.presentedViewController) cur = cur.presentedViewController;
    return cur;
}

- (UIWindow *)findAppKeyWindow {
    UIWindowScene *scene = [self findActiveScene];
    UIWindow *keyWindow = nil;
    for (UIWindow *w in scene.windows) {
        if (w == self.window) continue;     // skip our overlay
        if (w.isKeyWindow) { keyWindow = w; break; }
    }
    if (!keyWindow) {
        for (UIWindow *w in scene.windows) {
            if (w != self.window) { keyWindow = w; break; }
        }
    }
    return keyWindow;
}

- (void)presentSheet {
    if (self.currentSheet) {
        IPALog(@"[overlay] Sheet already up; skip");
        return;
    }

    UIWindow *keyWindow = [self findAppKeyWindow];
    UIViewController *host = [self topViewControllerFrom:keyWindow.rootViewController];
    if (!host) {
        IPALog([NSString stringWithFormat:
                  @"[overlay] presentSheet: no host VC  keyWindow=%@  root=%@",
                  keyWindow, keyWindow.rootViewController]);
        return;
    }

    PiyoSheetVC *sheet = [[PiyoSheetVC alloc] init];
    self.currentSheet = sheet;   // weak ref — auto-clears when sheet deallocates

    UINavigationController *nav =
        [[UINavigationController alloc] initWithRootViewController:sheet];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *pc = nav.sheetPresentationController;
        pc.detents = @[
            UISheetPresentationControllerDetent.mediumDetent,
            UISheetPresentationControllerDetent.largeDetent,
        ];
        pc.prefersGrabberVisible = YES;
    }
    [host presentViewController:nav animated:YES completion:^{
        IPALog(@"[overlay] Sheet presented");
    }];
}

// UIGestureRecognizerDelegate — only start the pan if the touch begins
// inside the right-edge strip. Belt-and-braces on top of the window's hit-test.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr
       shouldReceiveTouch:(UITouch *)touch {
    CGPoint p = [touch locationInView:gr.view];
    CGRect edge = CGRectMake(gr.view.bounds.size.width - kEdgeWidth,
                             0,
                             kEdgeWidth,
                             gr.view.bounds.size.height);
    return CGRectContainsPoint(edge, p);
}

@end

// ===========================================================================
// Public installer. Hooks UIApplicationDidFinishLaunchingNotification to
// build the window as soon as UIKit is alive, and DidBecomeActive as a
// second-chance in case the dylib loaded after DidFinishLaunching fired.
// ===========================================================================

static BOOL g_overlay_installed = NO;

void PSOverlayInstall(void) {
    if (g_overlay_installed) return;
    g_overlay_installed = YES;

    void (^build)(void) = ^{
        [[PiyoOverlayController shared] buildWindow];
    };

    // If UIApplication is already up (dylib loaded late), build now.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (UIApplication.sharedApplication) build();
    });
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidFinishLaunchingNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification * _Nonnull note) { build(); }];
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification * _Nonnull note) { build(); }];

    IPALog(@"[overlay] installer armed");
}

void PSOverlaySetProgress(NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{
        PiyoOverlayController *c = [PiyoOverlayController shared];
        UILabel *b = c.progressBanner;
        if (!b) return;    // overlay not built yet
        if (text.length == 0) {
            b.hidden = YES;
            b.text = nil;
        } else {
            // Pad with a space on either side so the rounded pill has
            // breathing room around the numbers.
            b.text = [NSString stringWithFormat:@"  %@  ", text];
            b.hidden = NO;
        }
    });
}
