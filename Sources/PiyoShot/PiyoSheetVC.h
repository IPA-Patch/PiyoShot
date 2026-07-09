#pragma once

#import <UIKit/UIKit.h>

// ===========================================================================
// PiyoSheetVC — the modal body PiyoOverlay presents when the right-edge
// swipe fires.
//
// Grouped UITableViewController in the KiouForge / Settings.app idiom.
// Sections:
//   • JSONL — file picker row, filename readout, validation counts
//   • 実行 — script run row (hands the loaded path to PiyoBatchRunner)
//     and current status
//   • 情報 — build version, commit, log path
//
// The Sheet is presented via UISheetPresentationController on iOS 15+
// with medium + large detents so the ShogiBoardView stays visible in
// the top portion of the screen (spec §6.2 recommendation A). Callers
// still use `[[PiyoSheetVC alloc] init]`; init forwards to
// `initWithStyle:UITableViewStyleInsetGrouped`.
// ===========================================================================

@interface PiyoSheetVC : UITableViewController
@end
