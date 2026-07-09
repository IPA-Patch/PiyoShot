#pragma once

#import <Foundation/Foundation.h>

// ===========================================================================
// PiyoBatchRunner — drives PiyoShogi's clipboard-load path for a whole
// JSONL file, one record at a time, capturing a PNG per SFEN.
//
// Startup: parse the JSONL, then drop every record whose
// piyo_capture/screen/<hash>.png AND piyo_capture/board/<hash>.png both
// already exist so the progress banner shows real work remaining
// (resume-safe). A half-captured record (only one of the two files
// present) gets re-run to fill the missing side.
//
// Per-record flow (see docs/spec §6, plus scripts/dist/hook_piyoshogi_paste.js):
//   1. Dismiss any modally-presented VC on top of VCTopMenu so the
//      paste selector fires from the same base state each iteration.
//   2. UIPasteboard.generalPasteboard.string = sfen.
//   3. Install a PSParseSFENCallback listener that counts
//      parseSFEN invocations. PiyoShogi 5.7.5 fires exactly 3 per paste
//      (validate / apply / redraw-prep).
//   4. Invoke -[VCTopMenu btnKifPasteClicked:] with nil sender.
//   5. When the 3rd parseSFEN lands with ret=1, wait 50ms for layout
//      to settle, then write two PNGs:
//        - piyo_capture/screen/<hash>.png: full key window with controls.
//        - piyo_capture/board/<hash>.png:  the ShogiBoardView alone
//          (board + both piece stands, tightly cropped).
//      Any earlier ret != 1 skips the record.
//   6. A 2 s watchdog covers the case where parseSFEN never fires the
//      expected count (malformed SFEN, unexpected UI branch).
//   7. Update the overlay progress banner ("XXX/N") and recurse to the
//      next record via dispatch_async(main).
//
// The runner is fire-and-forget: -startWithJsonlPath: returns immediately
// after enqueueing iteration 0. Progress lives entirely in the log +
// overlay banner; there is no cancel API by design.
// ===========================================================================

@interface PiyoBatchRunner : NSObject

// YES between the first record enqueue and the final "done" log line.
+ (BOOL)isRunning;

// Kick off the runner. No-op if already running or the file is empty of
// valid records.
+ (void)startWithJsonlPath:(NSString *)path;

@end
