#import "PiyoBatchRunner.h"
#import "PiyoOverlay.h"
#import "Internal.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

static NSString *const kMenuClassName    = @"PiyoShogi.VCTopMenu";
static NSString *const kPasteSelectorName = @"btnKifPasteClicked:";

// ShogiBoardView renders its content from the Position slot on every
// display pass. When VCMainView is already presented and we in-place
// re-paste (no dismiss/re-present), the underlying Position IS updated
// by parseSFEN — but the view has no signal that it needs to redraw,
// so the snapshot shows the previous position. Forcing setNeedsDisplay
// + displayIfNeeded on the board layer picks up the new Position, same
// trick scripts/dist/hook_piyoshogi_fastcapture.js does.
static NSString *const kBoardClassName   = @"PiyoShogi.ShogiBoardView";

// Every clipboard paste triggers exactly this many parseSFEN calls in
// PiyoShogi 5.7.5: one validation, one apply, one redraw-prep. When the
// third one lands with ret=1 we know the position has been fully applied
// and it's safe to snapshot — no fixed dispatch_after guessing.
static const int kParseSfenCallsPerPaste = 3;

// Tiny cushion after the 3rd parseSFEN so pending layout / redraw flush
// before we grab the bitmap.
static const NSTimeInterval kPostParseSettle = 0.05;

// Hard ceiling in case parseSFEN never fires 3 times (malformed SFEN,
// unexpected UI branch, etc.) — skip the record rather than hang.
static const NSTimeInterval kPasteTimeout = 2.0;

// ---------------------------------------------------------------------------
// Runtime state — module-local so we don't leak the class surface.
// ---------------------------------------------------------------------------

static BOOL         g_running = NO;
static NSArray     *g_records = nil;        // NSDictionary { sfen, hash }
static NSString    *g_captureDir = nil;     // piyo_capture (parent)
static NSString    *g_screenDir  = nil;     // piyo_capture/screen
static NSUInteger   g_doneCount = 0;
static NSUInteger   g_skipCount = 0;
// Wall-clock stamp when the current batch started iterating. Used by
// updateProgressBanner to compute the "N 件/s · 残 …" readout so the
// overlay banner doubles as an ETA display.
static CFAbsoluteTime g_batch_started = 0;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static UIWindow *findAppKeyWindow(void) {
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)sc;
        for (UIWindow *w in ws.windows) {
            if (w.windowLevel >= UIWindowLevelAlert) continue;
            if (w.isKeyWindow) return w;
        }
        for (UIWindow *w in ws.windows) {
            if (w.windowLevel >= UIWindowLevelAlert) continue;
            return w;
        }
    }
    return nil;
}

// Depth-first walk for a UIView subclass by its Swift-mangled class name.
// Used to punch a redraw request through to ShogiBoardView after an
// in-place re-paste.
static UIView *findViewOfClassName(UIView *v, NSString *className) {
    if (!v) return nil;
    if ([NSStringFromClass(v.class) isEqualToString:className]) return v;
    for (UIView *sub in v.subviews) {
        UIView *hit = findViewOfClassName(sub, className);
        if (hit) return hit;
    }
    return nil;
}

static UIViewController *findVCOfClass(UIViewController *root, Class cls) {
    if (!root || !cls) return nil;
    if ([root isKindOfClass:cls]) return root;
    for (UIViewController *child in root.childViewControllers) {
        UIViewController *hit = findVCOfClass(child, cls);
        if (hit) return hit;
    }
    UIViewController *pres = root.presentedViewController;
    if (pres) {
        UIViewController *hit = findVCOfClass(pres, cls);
        if (hit) return hit;
    }
    return nil;
}

// Retina-aware PNG snapshot with the UIKit-oriented CTM fix
// (Translate(0, pxH) + Scale(scale, -scale)) so the on-disk PNG is
// right-side-up. Ported from scripts/dist/hook_piyoshogi_fastcapture.js.
static NSData *snapshotViewAsPNG(UIView *view) {
    CGSize sz = view.bounds.size;
    if (sz.width <= 0 || sz.height <= 0) return nil;

    [view setNeedsDisplay];
    [view.layer displayIfNeeded];
    [view layoutIfNeeded];

    CGFloat scale = UIScreen.mainScreen.scale;
    size_t pxW = (size_t)ceil(sz.width  * scale);
    size_t pxH = (size_t)ceil(sz.height * scale);

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo bmi = kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little;
    CGContextRef ctx = CGBitmapContextCreate(NULL, pxW, pxH, 8, pxW * 4, cs, bmi);
    if (!ctx) { CGColorSpaceRelease(cs); return nil; }
    CGContextTranslateCTM(ctx, 0, pxH);
    CGContextScaleCTM(ctx, scale, -scale);
    [view.layer renderInContext:ctx];

    CGImageRef cgImg = CGBitmapContextCreateImage(ctx);
    NSData *png = nil;
    if (cgImg) {
        UIImage *img = [UIImage imageWithCGImage:cgImg];
        png = UIImagePNGRepresentation(img);
        CGImageRelease(cgImg);
    }
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    return png;
}

// Human-readable "3h 42m" / "12m 30s" / "8s" formatter used for the ETA.
static NSString *formatETASeconds(NSTimeInterval s) {
    if (s < 60)   return [NSString stringWithFormat:@"%.0fs", s];
    if (s < 3600) {
        NSInteger m = (NSInteger)(s / 60);
        NSInteger sec = (NSInteger)fmod(s, 60);
        return [NSString stringWithFormat:@"%ldm %02lds", (long)m, (long)sec];
    }
    NSInteger h = (NSInteger)(s / 3600);
    NSInteger m = (NSInteger)fmod(s / 60, 60);
    return [NSString stringWithFormat:@"%ldh %02ldm", (long)h, (long)m];
}

static void updateProgressBanner(NSUInteger idx, NSUInteger total) {
    NSUInteger done = MIN(idx, total);
    // Skip the ETA math until we have at least a couple of iterations
    // under our belt — the first sample would be dominated by cold-start
    // effects (paste flow warming up, VCMainView first present).
    if (done < 2 || g_batch_started == 0) {
        PSOverlaySetProgress(
            [NSString stringWithFormat:@"%lu/%lu",
                                        (unsigned long)done,
                                        (unsigned long)total]);
        return;
    }
    NSTimeInterval elapsed = CFAbsoluteTimeGetCurrent() - g_batch_started;
    if (elapsed <= 0.5) {
        PSOverlaySetProgress(
            [NSString stringWithFormat:@"%lu/%lu",
                                        (unsigned long)done,
                                        (unsigned long)total]);
        return;
    }
    double ratePerSec = (double)done / elapsed;
    NSUInteger remaining = total > done ? total - done : 0;
    NSTimeInterval eta = ratePerSec > 0 ? remaining / ratePerSec : 0;
    PSOverlaySetProgress(
        [NSString stringWithFormat:@"%lu/%lu · %.1f/s · ETA %@",
                                    (unsigned long)done,
                                    (unsigned long)total,
                                    ratePerSec,
                                    formatETASeconds(eta)]);
}

// Forward decl
static void runIteration(NSUInteger idx);

// ---------------------------------------------------------------------------
// Iteration body — the meat of the batch. Runs entirely on main queue so
// UIKit calls (VC lookup, pasteboard, paste invocation, snapshot) are
// safe. Uses dispatch_async(main) to recurse without stack growth.
// ---------------------------------------------------------------------------

static void finishIteration(NSUInteger idx) {
    updateProgressBanner(idx + 1, g_records.count);
    dispatch_async(dispatch_get_main_queue(), ^{
        runIteration(idx + 1);
    });
}

static void skipIteration(NSUInteger idx, NSString *reason, NSString *hash) {
    g_skipCount++;
    IPALog([NSString stringWithFormat:
              @"[batch %lu/%lu] hash=%@ SKIP (%@)",
              (unsigned long)(idx + 1),
              (unsigned long)g_records.count,
              hash, reason]);
    finishIteration(idx);
}

static void runIteration(NSUInteger idx) {
    if (idx >= g_records.count) {
        NSUInteger total = g_records.count;
        IPALog([NSString stringWithFormat:
                  @"[batch] === done: %lu records, %lu written, %lu skipped ===",
                  (unsigned long)total,
                  (unsigned long)g_doneCount,
                  (unsigned long)g_skipCount]);
        PSOverlaySetProgress(
            [NSString stringWithFormat:@"Done %lu/%lu",
                                       (unsigned long)g_doneCount,
                                       (unsigned long)total]);
        g_running       = NO;
        g_records       = nil;
        g_captureDir    = nil;
        g_screenDir     = nil;
        g_batch_started = 0;
        return;
    }

    NSDictionary *rec = g_records[idx];
    NSString *sfen = rec[@"sfen"];
    NSString *hash = rec[@"hash"];
    NSString *fileName = [hash stringByAppendingString:@".png"];
    NSString *screenPath = [g_screenDir stringByAppendingPathComponent:fileName];

    UIWindow *keyWin = findAppKeyWindow();
    if (!keyWin) { skipIteration(idx, @"no key window", hash); return; }

    Class menuCls = NSClassFromString(kMenuClassName);
    if (!menuCls) { skipIteration(idx, @"no VCTopMenu class", hash); return; }

    UIViewController *menu = findVCOfClass(keyWin.rootViewController, menuCls);
    if (!menu) {
        skipIteration(idx, @"no VCTopMenu instance — open the top menu first",
                       hash);
        return;
    }

    SEL pasteSel = NSSelectorFromString(kPasteSelectorName);
    if (![menu respondsToSelector:pasteSel]) {
        skipIteration(idx, @"btnKifPasteClicked: missing", hash);
        return;
    }

    // If VCMainView (or any other presentation) is stacked on top of
    // VCTopMenu from the previous iteration, dismiss it so paste fires
    // from the same clean state each time. Then chain into the actual
    // paste + snapshot after the dismiss completes.
    void (^doPaste)(void) = ^{
        __block int callCount = 0;
        __block BOOL finished = NO;

        UIPasteboard.generalPasteboard.string = sfen;
        PSLastParseSFENRet = -1;

        // Snapshot + write + advance. Called exactly once via the
        // `finished` guard whichever exit path we take. Screen-only —
        // the board crop was tried out and dropped: it needed a
        // dismiss-before-paste cycle that made VCMainView mid-animation
        // when we snapshotted, tanking the pipeline.
        void (^snapshotAndAdvance)(void) = ^{
            UIWindow *win = findAppKeyWindow() ?: keyWin;

            // Force ShogiBoardView to redraw from the freshly-parsed
            // Position. Without this the layer keeps its previous
            // content because in-place re-paste doesn't fire a
            // presentation → viewWillAppear that would otherwise
            // invalidate the layer for us.
            UIView *board = findViewOfClassName(win, kBoardClassName);
            if (board) {
                [board setNeedsDisplay];
                [board.layer setNeedsDisplay];
                [board.layer displayIfNeeded];
                [board layoutIfNeeded];
            }

            NSData *screenPng = snapshotViewAsPNG(win);
            if (!screenPng) {
                skipIteration(idx, @"screen snapshot returned nil", hash);
                return;
            }
            NSError *werr = nil;
            BOOL wrote = [screenPng writeToFile:screenPath
                                        options:NSDataWritingAtomic
                                          error:&werr];
            if (!wrote) {
                skipIteration(idx,
                    [NSString stringWithFormat:@"screen write failed: %@",
                        werr.localizedDescription ?: @"unknown"],
                    hash);
                return;
            }
            g_doneCount++;
            IPALog([NSString stringWithFormat:
                      @"[batch %lu/%lu] hash=%@ screen=%lu",
                      (unsigned long)(idx + 1),
                      (unsigned long)g_records.count,
                      hash,
                      (unsigned long)screenPng.length]);
            finishIteration(idx);
        };

        // Install the parseSFEN listener. The hook re-hops onto main
        // before firing, so every invocation of this block already runs
        // on the main queue — safe to touch UIKit / mutate globals.
        PSParseSFENCallback = ^(int32_t ret) {
            if (finished) return;
            callCount++;
            if (ret != 1) {
                finished = YES;
                PSParseSFENCallback = nil;
                skipIteration(idx,
                    [NSString stringWithFormat:@"parseSFEN=%d (call %d)",
                        (int)ret, callCount],
                    hash);
                return;
            }
            if (callCount >= kParseSfenCallsPerPaste) {
                finished = YES;
                PSParseSFENCallback = nil;
                // Let any pending layout / redraw settle before grabbing
                // the bitmap. 50ms is empirically enough on 5.7.5.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(kPostParseSettle * NSEC_PER_SEC)),
                               dispatch_get_main_queue(),
                               snapshotAndAdvance);
            }
        };

        IMP imp = [menu methodForSelector:pasteSel];
        ((void (*)(id, SEL, id))imp)(menu, pasteSel, nil);

        // Watchdog. If parseSFEN never lands 3 times (SFEN silently
        // rejected before the parser runs, unexpected UI branch, etc.)
        // this fires, clears the listener, and skips the record.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(kPasteTimeout * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (finished) return;
            finished = YES;
            PSParseSFENCallback = nil;
            skipIteration(idx,
                [NSString stringWithFormat:@"parseSFEN timeout (%d/%d)",
                    callCount, kParseSfenCallsPerPaste],
                hash);
        });
    };

    // Fire paste directly. Do NOT dismiss any presented VC first — the
    // dismiss+re-present cycle put VCMainView mid-animation when the
    // snapshot ran, tanking hundreds of records in a row. In-place
    // re-paste (VCTopMenu.btnKifPasteClicked: while VCMainView already
    // shown) is the behaviour that empirically wrote hundreds of PNGs
    // without a hitch during the initial batch.
    doPaste();
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

@implementation PiyoBatchRunner

+ (BOOL)isRunning { return g_running; }

+ (void)startWithJsonlPath:(NSString *)path {
    if (g_running) {
        IPALog(@"[batch] already running — ignored second start");
        return;
    }
    if (path.length == 0) {
        IPALog(@"[batch] no JSONL path");
        return;
    }

    NSError *rerr = nil;
    NSString *contents = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding
                                                      error:&rerr];
    if (!contents) {
        IPALog([NSString stringWithFormat:@"[batch] read failed: %@", rerr]);
        return;
    }

    NSMutableArray *allRecords = [NSMutableArray array];
    for (NSString *raw in [contents componentsSeparatedByString:@"\n"]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:
                          NSCharacterSet.whitespaceCharacterSet];
        if (line.length == 0) continue;
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![obj isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *rec = obj;
        if ([rec[@"sfen"] isKindOfClass:NSString.class] &&
            [rec[@"hash"] isKindOfClass:NSString.class]) {
            [allRecords addObject:rec];
        }
    }
    if (allRecords.count == 0) {
        IPALog(@"[batch] no valid records — nothing to do");
        return;
    }

    NSString *docDir = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *captureDir = [docDir stringByAppendingPathComponent:@"piyo_capture"];
    NSString *screenDir  = [captureDir stringByAppendingPathComponent:@"screen"];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *d in @[captureDir, screenDir]) {
        [fm createDirectoryAtPath:d
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];
    }

    // Filter out records whose screen PNG is already on disk so the
    // progress banner reflects real work-to-do, not "X/1000" that
    // mostly ticks through cached hits. Resume-safe.
    NSString *fileNameSuffix = @".png";
    NSMutableArray *records = [NSMutableArray arrayWithCapacity:allRecords.count];
    for (NSDictionary *rec in allRecords) {
        NSString *fileName = [rec[@"hash"] stringByAppendingString:fileNameSuffix];
        NSString *screen = [screenDir stringByAppendingPathComponent:fileName];
        if (![fm fileExistsAtPath:screen]) {
            [records addObject:rec];
        }
    }
    NSUInteger alreadyCaptured = allRecords.count - records.count;
    if (records.count == 0) {
        IPALog([NSString stringWithFormat:
                  @"[batch] all %lu records already captured — nothing to do",
                  (unsigned long)allRecords.count]);
        return;
    }

    g_running       = YES;
    g_records       = records;
    g_captureDir    = captureDir;
    g_screenDir     = screenDir;
    g_doneCount     = 0;
    g_skipCount     = 0;
    g_batch_started = CFAbsoluteTimeGetCurrent();

    IPALog([NSString stringWithFormat:
              @"[batch] === start: %lu to run (%lu already captured, %lu total) → %@ ===",
              (unsigned long)records.count,
              (unsigned long)alreadyCaptured,
              (unsigned long)allRecords.count,
              captureDir]);
    updateProgressBanner(0, records.count);

    dispatch_async(dispatch_get_main_queue(), ^{
        runIteration(0);
    });
}

@end
