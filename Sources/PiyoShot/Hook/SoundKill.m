#import "Internal.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ===========================================================================
// Hook_SoundKill — NoOp every -[AVAudioPlayer play] call.
//
// Motivation:
//
//   PiyoShogi plays a piece-move / paste-success SE on every clipboard
//   paste (that's what -[VCTopMenu btnKifPasteClicked:] wires up). At
//   normal use — one paste every few seconds — that's fine. At the batch
//   runner's ~143 ms/record cadence it's not: AVAudioPlayer allocates a
//   fresh AudioQueue per -play, and the per-process AudioQueue ceiling
//   (a few hundred) starts biting after ~10 minutes of continuous
//   pastes. When the audio session goes into that half-broken state, the
//   next -[UINib instantiateWithOwner:options:] that touches an audio-
//   linked resource raises an unhandled NSException — which is the
//   deterministic iteration-4841 crash the Tweak.m header block
//   describes.
//
// Fix: swizzle -[AVAudioPlayer play] to a NoOp returning YES. Every
// PiyoShogi SE playback path funnels through this selector, and the
// return value tells the caller "playback started fine" so nothing
// downstream trips on a nil player. Batch-mode users don't hear the SEs
// anyway (device face-down on a desk for 24 min); non-batch users still
// go through the same NoOp but the practical hit is inaudible —
// PiyoShogi doesn't have looping BGM that would notice.
//
// Runtime-only ObjC, mirrors AdHide.m's shape. No binpatch slot; safe
// on JB, jailed, and CHINLAN builds.
// ===========================================================================

typedef BOOL (*play_imp_t)(id, SEL);
static play_imp_t orig_avaudioplayer_play = NULL;

static BOOL hookAVAudioPlayerPlay(id self, SEL _cmd) {
    // Deliberately drop the call. Return YES so callers that gate on
    // the result ("if ([player play]) { ... }") take the success branch
    // and don't fall into an error path that itself might touch UIKit
    // or spin up a fallback player.
    (void)self;
    (void)_cmd;
    (void)orig_avaudioplayer_play; // suppress unused warning; kept as an escape hatch
    return YES;
}

// -[AVAudioPlayer playAtTime:] takes a scheduling timestamp but resolves
// to the same AudioQueue path. Silence it identically so any caller
// that switched to the timed variant doesn't accidentally revive the
// queue-leak we just closed.
typedef BOOL (*play_at_time_imp_t)(id, SEL, NSTimeInterval);
static play_at_time_imp_t orig_avaudioplayer_play_at = NULL;

static BOOL hookAVAudioPlayerPlayAtTime(id self, SEL _cmd, NSTimeInterval when) {
    (void)self;
    (void)_cmd;
    (void)when;
    (void)orig_avaudioplayer_play_at;
    return YES;
}

static void installNow(void) {
    Class cls = NSClassFromString(@"AVAudioPlayer");
    if (!cls) {
        IPALog(@"[soundkill] AVAudioPlayer class not found — skipping");
        return;
    }

    // -[AVAudioPlayer play]
    Method m = class_getInstanceMethod(cls, @selector(play));
    if (m && !orig_avaudioplayer_play) {
        orig_avaudioplayer_play = (play_imp_t)method_getImplementation(m);
        method_setImplementation(m, (IMP)hookAVAudioPlayerPlay);
        IPALog(@"[soundkill] noop  -[AVAudioPlayer play]");
    }

    // -[AVAudioPlayer playAtTime:]
    Method m2 = class_getInstanceMethod(cls, @selector(playAtTime:));
    if (m2 && !orig_avaudioplayer_play_at) {
        orig_avaudioplayer_play_at = (play_at_time_imp_t)method_getImplementation(m2);
        method_setImplementation(m2, (IMP)hookAVAudioPlayerPlayAtTime);
        IPALog(@"[soundkill] noop  -[AVAudioPlayer playAtTime:]");
    }
}

void PSInstallSoundKillHook(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // AVFoundation is available immediately at constructor time
        // (it's a system framework, not linked lazily), so no need to
        // wait for DidFinishLaunching like AdHide does. Installing
        // early ensures we're in place before PiyoShogi's boot SE ever
        // fires.
        installNow();
    });
}
