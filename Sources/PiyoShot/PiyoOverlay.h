#pragma once

#import <Foundation/Foundation.h>

// ===========================================================================
// PiyoOverlay — transparent UIWindow that catches the corner-swipe
// trigger for the batch-runner Sheet.
//
// Behaviour (spec §4):
//   - A UIWindow pinned at windowLevel = UIWindowLevelAlert + 1000 so it
//     stays above whatever PiyoShogi puts up.
//   - pointInside:withEvent: returns YES only for the bottom-right
//     100×100 pt hit region — every other touch passes through to
//     PiyoShogi untouched.
//   - A UIPanGestureRecognizer inside that region watches for a
//     bottom-right → top-left drag (dx > 60 && dy > 60). When it fires,
//     PiyoSheetVC is presented over the current key window's top view
//     controller.
//
//   PSOverlayInstall()
//     Lazy-init entry point. Safe to call from the dylib constructor:
//     it observes UIApplicationDidFinishLaunchingNotification and
//     builds the UIWindow once the first UIScene is up. Second and
//     later calls are no-ops.
// ===========================================================================

void PSOverlayInstall(void);

// Update the progress banner shown at the bottom-centre of the overlay
// window. Pass nil to hide. Safe to call from any thread — the call
// hops to main. No-op if the overlay window hasn't been built yet.
void PSOverlaySetProgress(NSString * _Nullable text);
