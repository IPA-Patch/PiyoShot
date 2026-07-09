#import "PiyoSheetVC.h"
#import "PiyoBatchRunner.h"
#import "Internal.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <mach-o/dyld.h>
#import <CommonCrypto/CommonDigest.h>

// Default JSONL shipped alongside the tweak. Two distribution shapes
// need to work:
//
//   • JB / rootless deb: layout/Library/Application Support/PiyoShot/
//     lands at /var/jb/Library/Application Support/PiyoShot/ on device.
//   • CHINLAN sideloaded IPA: build_patched_ipa.sh copies the dylib
//     into Payload/PiyoShogi.app/Frameworks/. The Makefile's ipa target
//     drops position.jsonl next to it, so at runtime the file sits at
//     `dirname(PiyoShot.dylib)/position.jsonl`.
//
// findBundledJsonlPath() probes both. Whichever matches first wins.
static NSString *const kBundledJbPath =
    @"/var/jb/Library/Application Support/PiyoShot/position.jsonl";
static NSString *const kBundledJsonlBasename    = @"position.jsonl";
static NSString *const kBundledDocumentsName    = @"position_bundled.jsonl";

static NSString *findBundledJsonlPath(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([fm isReadableFileAtPath:kBundledJbPath]) {
        return kBundledJbPath;
    }
    // Sideload: walk dyld image list, find our own dylib, look next to it.
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *cname = _dyld_get_image_name(i);
        if (!cname) continue;
        NSString *path = @(cname);
        if (![path.lastPathComponent isEqualToString:@"PiyoShot.dylib"]) continue;
        NSString *sib = [path.stringByDeletingLastPathComponent
                            stringByAppendingPathComponent:kBundledJsonlBasename];
        if ([fm isReadableFileAtPath:sib]) return sib;
    }
    return nil;
}

// ===========================================================================
// PiyoSheetVC — grouped-table Sheet UI.
//
// Three sections in inset-grouped style (KiouForge / Settings.app look):
//   JSONL — file picker, filename readout, validation counts
//   実行   — kicks off PiyoBatchRunner over the loaded JSONL
//   情報   — build version, commit, log path
//
// Batch execution itself lives in PiyoBatchRunner. The 実行 row's only
// job is to sanity-check that a validated JSONL is loaded and then hand
// its path to +[PiyoBatchRunner startWithJsonlPath:]. Progress is shown
// on the overlay window's bottom-centre banner (updated by the runner),
// not on this sheet — the sheet gets dismissed before iteration starts.
// ===========================================================================

// Section / row indices. Kept as anonymous enums so they compare directly
// against the NSInteger IndexPath fields the table delegate hands us.
enum { PiyoSecJsonl = 0, PiyoSecRun, PiyoSecInfo, PiyoSecCount };
enum { PiyoJsonlPick = 0, PiyoJsonlName, PiyoJsonlCount, PiyoJsonlRowCount };
enum { PiyoRunExecute = 0, PiyoRunDedup, PiyoRunStatus, PiyoRunRowCount };
enum { PiyoInfoVersion = 0, PiyoInfoCommit, PiyoInfoLog, PiyoInfoRowCount };

@interface PiyoSheetVC () <UIDocumentPickerDelegate>
// nil until a file has been picked and copied into Documents. Batch
// runner (P4+) reopens by path, not by picker URL.
@property (nonatomic, copy)   NSString *loadedPath;
@property (nonatomic, copy)   NSString *loadedFileName;
@property (nonatomic, assign) NSUInteger totalCount;
@property (nonatomic, assign) NSUInteger validCount;
@property (nonatomic, assign) NSUInteger invalidCount;
// Records whose piyo_capture/screen/<hash>.png already exists — same
// condition PiyoBatchRunner's upfront filter uses, so the count row
// previews "残 N" before the batch even starts.
@property (nonatomic, assign) NSUInteger capturedCount;
@property (nonatomic, copy)   NSString *statusMessage;
@property (nonatomic, assign) BOOL      running;
@end

@implementation PiyoSheetVC

// UITableViewController's designated init is -initWithStyle:. Force
// inset-grouped regardless of what the caller passed so the sheet keeps
// a consistent look; PiyoOverlay hands us a bare `-init`.
- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (instancetype)initWithStyle:(UITableViewStyle)style {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"PiyoShot";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                       target:self
                                                       action:@selector(dismissSheet)];
    self.statusMessage = @"Idle";

    // Auto-load the bundled JSONL default if the user hasn't picked
    // anything this session. The picker still overrides for one-off
    // custom runs.
    if (!self.loadedPath) {
        [self loadBundledJsonlIfAvailable];
    }
}

// ---------------------------------------------------------------------------
// Bundled default
// ---------------------------------------------------------------------------

- (void)loadBundledJsonlIfAvailable {
    NSString *src = findBundledJsonlPath();
    if (!src) {
        IPALog(@"[sheet] bundled JSONL not found in JB path or dylib sibling — deb / IPA not carrying it");
        return;
    }

    NSString *docDir = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dst = [docDir stringByAppendingPathComponent:kBundledDocumentsName];

    NSError *err = nil;
    NSData *data = [NSData dataWithContentsOfFile:src
                                          options:0
                                            error:&err];
    if (!data) {
        IPALog([NSString stringWithFormat:@"[sheet] bundled read failed: %@", err]);
        return;
    }
    if (![data writeToFile:dst options:NSDataWritingAtomic error:&err]) {
        IPALog([NSString stringWithFormat:@"[sheet] bundled write failed: %@", err]);
        return;
    }
    self.loadedPath     = dst;
    self.loadedFileName = [kBundledDocumentsName stringByReplacingOccurrencesOfString:@".jsonl"
                                                                            withString:@" (bundled)"];
    self.totalCount = self.validCount = self.invalidCount = self.capturedCount = 0;
    self.statusMessage = @"Validating bundled JSONL…";
    IPALog([NSString stringWithFormat:@"[sheet] bundled JSONL loaded → %@", dst]);
    [self validateAsync:dst];
}

// ---------------------------------------------------------------------------
// UITableViewDataSource
// ---------------------------------------------------------------------------

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return PiyoSecCount;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case PiyoSecJsonl: return PiyoJsonlRowCount;
        case PiyoSecRun:   return PiyoRunRowCount;
        case PiyoSecInfo:  return PiyoInfoRowCount;
    }
    return 0;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case PiyoSecJsonl: return @"JSONL";
        case PiyoSecRun:   return @"Run";
        case PiyoSecInfo:  return @"Info";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv
         cellForRowAtIndexPath:(NSIndexPath *)ip {
    switch (ip.section) {
        case PiyoSecJsonl: return [self jsonlCellForRow:ip.row];
        case PiyoSecRun:   return [self runCellForRow:ip.row];
        case PiyoSecInfo:  return [self infoCellForRow:ip.row];
    }
    return [[UITableViewCell alloc] init];
}

- (UITableViewCell *)jsonlCellForRow:(NSInteger)row {
    switch (row) {
        case PiyoJsonlPick: {
            UITableViewCell *c = [[UITableViewCell alloc]
                initWithStyle:UITableViewCellStyleDefault
                reuseIdentifier:nil];
            c.textLabel.text = @"Choose JSONL file";
            c.textLabel.textColor = self.view.tintColor;
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return c;
        }
        case PiyoJsonlName: {
            UITableViewCell *c = [[UITableViewCell alloc]
                initWithStyle:UITableViewCellStyleSubtitle
                reuseIdentifier:nil];
            c.textLabel.text = @"File";
            c.detailTextLabel.text = self.loadedFileName ?: @"(none)";
            c.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
            c.selectionStyle = UITableViewCellSelectionStyleNone;
            return c;
        }
        case PiyoJsonlCount: {
            // Subtitle style so the count line + capture-status line
            // stack visibly. detailTextLabel is the secondary line.
            UITableViewCell *c = [[UITableViewCell alloc]
                initWithStyle:UITableViewCellStyleSubtitle
                reuseIdentifier:nil];
            if (self.loadedPath) {
                c.textLabel.text = [NSString stringWithFormat:
                    @"total %lu / valid %lu / invalid %lu",
                    (unsigned long)self.totalCount,
                    (unsigned long)self.validCount,
                    (unsigned long)self.invalidCount];
                NSUInteger remaining = (self.validCount > self.capturedCount)
                    ? (self.validCount - self.capturedCount) : 0;
                c.detailTextLabel.text = [NSString stringWithFormat:
                    @"captured %lu / remaining %lu",
                    (unsigned long)self.capturedCount,
                    (unsigned long)remaining];
            } else {
                c.textLabel.text = @"Records";
                c.detailTextLabel.text = @"—";
            }
            c.textLabel.font = [UIFont monospacedDigitSystemFontOfSize:15
                                                                weight:UIFontWeightRegular];
            c.detailTextLabel.font = [UIFont monospacedDigitSystemFontOfSize:13
                                                                     weight:UIFontWeightRegular];
            c.selectionStyle = UITableViewCellSelectionStyleNone;
            return c;
        }
    }
    return [[UITableViewCell alloc] init];
}

- (UITableViewCell *)runCellForRow:(NSInteger)row {
    switch (row) {
        case PiyoRunExecute: {
            UITableViewCell *c = [[UITableViewCell alloc]
                initWithStyle:UITableViewCellStyleDefault
                reuseIdentifier:nil];
            NSUInteger remaining = self.validCount > self.capturedCount
                ? self.validCount - self.capturedCount : 0;
            c.textLabel.text = remaining > 0
                ? [NSString stringWithFormat:@"Run (%lu remaining)", (unsigned long)remaining]
                : @"Run";
            c.textLabel.textAlignment = NSTextAlignmentCenter;
            BOOL enabled = (remaining > 0) && !self.running;
            c.textLabel.textColor = enabled
                ? self.view.tintColor
                : [UIColor tertiaryLabelColor];
            c.selectionStyle = enabled
                ? UITableViewCellSelectionStyleDefault
                : UITableViewCellSelectionStyleNone;
            c.userInteractionEnabled = enabled;
            return c;
        }
        case PiyoRunDedup: {
            UITableViewCell *c = [[UITableViewCell alloc]
                initWithStyle:UITableViewCellStyleDefault
                reuseIdentifier:nil];
            c.textLabel.text = @"Hash check (dedupe)";
            c.textLabel.textAlignment = NSTextAlignmentCenter;
            BOOL enabled = !self.running;
            // systemRed to signal "destructive" — this row unlinks files.
            c.textLabel.textColor = enabled
                ? [UIColor systemRedColor]
                : [UIColor tertiaryLabelColor];
            c.selectionStyle = enabled
                ? UITableViewCellSelectionStyleDefault
                : UITableViewCellSelectionStyleNone;
            c.userInteractionEnabled = enabled;
            return c;
        }
        case PiyoRunStatus: {
            UITableViewCell *c = [[UITableViewCell alloc]
                initWithStyle:UITableViewCellStyleSubtitle
                reuseIdentifier:nil];
            c.textLabel.text = @"Status";
            c.detailTextLabel.text = self.statusMessage ?: @"—";
            c.detailTextLabel.numberOfLines = 0;
            c.selectionStyle = UITableViewCellSelectionStyleNone;
            return c;
        }
    }
    return [[UITableViewCell alloc] init];
}

- (UITableViewCell *)infoCellForRow:(NSInteger)row {
    UITableViewCell *c = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleValue1
        reuseIdentifier:nil];
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    switch (row) {
        case PiyoInfoVersion:
            c.textLabel.text = @"Version";
            c.detailTextLabel.text = [NSString stringWithFormat:@"%s", PIYOSHOT_VERSION];
            break;
        case PiyoInfoCommit:
            c.textLabel.text = @"Commit";
            c.detailTextLabel.text = [NSString stringWithFormat:@"%s", PIYOSHOT_COMMIT];
            break;
        case PiyoInfoLog: {
            c.textLabel.text = @"Log";
            NSString *docDir = NSSearchPathForDirectoriesInDomains(
                NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            c.detailTextLabel.text =
                [docDir stringByAppendingPathComponent:@"piyoshot.log"];
            c.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingHead;
            break;
        }
    }
    c.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    return c;
}

// ---------------------------------------------------------------------------
// UITableViewDelegate
// ---------------------------------------------------------------------------

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == PiyoSecJsonl && ip.row == PiyoJsonlPick) {
        [self openPicker];
    } else if (ip.section == PiyoSecRun && ip.row == PiyoRunExecute) {
        [self startBatch];
    } else if (ip.section == PiyoSecRun && ip.row == PiyoRunDedup) {
        [self startDedup];
    }
}

// ---------------------------------------------------------------------------
// Hash-based dedup — mirror of scripts/dedup_captures.py in-app.
// Rationale: if the batch runner ever fails to refresh the board view
// between iterations, the same on-screen image gets saved under two
// different <hash>.png filenames. Byte-identical PNGs are proof that
// the SFENs they claim to represent can't both be right — and we can't
// tell which one is honest — so we drop every member of every duplicate
// group. The batch runner's upfront filter picks the missing hashes
// back up on the next run.
// ---------------------------------------------------------------------------

- (void)startDedup {
    if (self.running) return;
    if ([PiyoBatchRunner isRunning]) {
        self.statusMessage = @"Batch is running; hash check disabled";
        [self.tableView reloadData];
        return;
    }
    self.running = YES;
    self.statusMessage = @"Starting hash check…";
    [self.tableView reloadData];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *docDir = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *screenDir = [[docDir stringByAppendingPathComponent:@"piyo_capture"]
                                stringByAppendingPathComponent:@"screen"];
        NSFileManager *fm = NSFileManager.defaultManager;
        NSArray<NSString *> *entries =
            [fm contentsOfDirectoryAtPath:screenDir error:nil] ?: @[];
        NSMutableArray<NSString *> *pngs = [NSMutableArray array];
        for (NSString *e in entries) {
            if ([e.pathExtension.lowercaseString isEqualToString:@"png"]) {
                [pngs addObject:e];
            }
        }
        NSUInteger total = pngs.count;
        IPALog([NSString stringWithFormat:@"[dedup] scanning %lu files under %@",
                (unsigned long)total, screenDir]);

        // hash -> mutable list of relative filenames sharing that content
        NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *groups =
            [NSMutableDictionary dictionaryWithCapacity:total];
        NSUInteger tick = 0;
        for (NSString *name in pngs) {
            // @autoreleasepool per iteration is load-bearing: without it
            // the NSData buffers + hex strings accumulate to the outer
            // dispatch block's pool and OOM the sandboxed app around a
            // few thousand files (CHINLAN sideload has a much tighter
            // memory ceiling than the JB rootless variant).
            @autoreleasepool {
                NSString *full = [screenDir stringByAppendingPathComponent:name];
                NSData *bytes = [NSData dataWithContentsOfFile:full
                                                       options:NSDataReadingMappedIfSafe
                                                         error:nil];
                if (!bytes) continue;
                unsigned char digest[CC_SHA256_DIGEST_LENGTH];
                CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, digest);
                // Emit the hex digest without NSMutableString/appendFormat —
                // a fixed-size char buffer + a single alloc of NSString
                // is much cheaper for 10k iterations.
                char hexbuf[CC_SHA256_DIGEST_LENGTH * 2 + 1];
                static const char kHex[] = "0123456789abcdef";
                for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
                    hexbuf[i * 2]     = kHex[(digest[i] >> 4) & 0xF];
                    hexbuf[i * 2 + 1] = kHex[digest[i] & 0xF];
                }
                hexbuf[sizeof(hexbuf) - 1] = 0;
                NSString *hex = [[NSString alloc]
                    initWithBytes:hexbuf
                           length:sizeof(hexbuf) - 1
                         encoding:NSASCIIStringEncoding];
                NSMutableArray *list = groups[hex];
                if (!list) { list = [NSMutableArray array]; groups[hex] = list; }
                [list addObject:name];

                if ((++tick % 500) == 0 || tick == total) {
                    NSUInteger done = tick;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        self.statusMessage = [NSString stringWithFormat:
                            @"Hashing %lu/%lu", (unsigned long)done,
                            (unsigned long)total];
                        [self.tableView reloadData];
                    });
                }
            }
        }

        NSUInteger dupGroups = 0, deleted = 0;
        for (NSString *h in groups) {
            NSArray *paths = groups[h];
            if (paths.count < 2) continue;
            dupGroups++;
            for (NSString *name in paths) {
                NSString *full = [screenDir stringByAppendingPathComponent:name];
                if ([fm removeItemAtPath:full error:nil]) deleted++;
            }
        }
        IPALog([NSString stringWithFormat:
                @"[dedup] done: total=%lu dup_groups=%lu deleted=%lu",
                (unsigned long)total, (unsigned long)dupGroups,
                (unsigned long)deleted]);

        dispatch_async(dispatch_get_main_queue(), ^{
            self.running = NO;
            self.statusMessage = [NSString stringWithFormat:
                @"Done: %lu duplicate groups, %lu files deleted",
                (unsigned long)dupGroups, (unsigned long)deleted];
            [self.tableView reloadData];
            // Refresh the JSONL section's 撮影済 / 残 numbers so the
            // freshly-freed hashes flip back to "残".
            if (self.loadedPath) [self validateAsync:self.loadedPath];
        });
    });
}

// ---------------------------------------------------------------------------
// File picker — NSData round-trip so iCloud-Drive dataless placeholders
// materialise before copy. `copyItemAtURL:` fails there with "no such file".
// ---------------------------------------------------------------------------

- (void)openPicker {
    NSMutableArray<UTType *> *types = [NSMutableArray array];
    UTType *jsonl = [UTType typeWithFilenameExtension:@"jsonl"];
    if (jsonl) [types addObject:jsonl];
    [types addObject:UTTypePlainText];

    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc]
            initForOpeningContentTypes:types];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
        didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *src = urls.firstObject;
    if (!src) return;

    BOOL scoped = [src startAccessingSecurityScopedResource];
    NSError *err = nil;
    NSData *data = [NSData dataWithContentsOfURL:src options:0 error:&err];
    if (scoped) [src stopAccessingSecurityScopedResource];

    if (!data) {
        IPALog([NSString stringWithFormat:@"[sheet] read failed: %@ (%@)",
                  src, err]);
        self.statusMessage = [NSString stringWithFormat:@"Read failed: %@",
                              err.localizedDescription ?: @"unknown"];
        [self.tableView reloadData];
        return;
    }

    NSString *docDir = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *fileName = src.lastPathComponent ?: @"piyo_input.jsonl";
    NSString *dst = [docDir stringByAppendingPathComponent:fileName];
    if (![data writeToFile:dst options:NSDataWritingAtomic error:&err]) {
        IPALog([NSString stringWithFormat:@"[sheet] write failed: %@", err]);
        self.statusMessage = [NSString stringWithFormat:@"Write failed: %@",
                              err.localizedDescription ?: @"unknown"];
        [self.tableView reloadData];
        return;
    }

    self.loadedPath     = dst;
    self.loadedFileName = fileName;
    self.totalCount = self.validCount = self.invalidCount = self.capturedCount = 0;
    self.statusMessage = @"Validating…";
    [self.tableView reloadData];
    [self validateAsync:dst];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    // no-op — leave any previously-loaded file in place
}

// ---------------------------------------------------------------------------
// Validation — line-by-line JSON parse. Valid rows have both `sfen` and
// `hash` string fields (matches the batch runner's expectation, spec §6.1).
// ---------------------------------------------------------------------------

- (void)validateAsync:(NSString *)path {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *rerr = nil;
        NSString *contents = [NSString stringWithContentsOfFile:path
                                                       encoding:NSUTF8StringEncoding
                                                          error:&rerr];
        if (!contents) {
            IPALog([NSString stringWithFormat:@"[sheet] read failed: %@", rerr]);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.statusMessage = @"Read failed";
                [self.tableView reloadData];
            });
            return;
        }

        // Preload the two capture-dir listings once so we can do
        // membership checks in O(1) per record instead of a stat() per
        // hash. Keeps 10k-record validation snappy.
        NSString *docDir = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *screenDir = [[docDir stringByAppendingPathComponent:@"piyo_capture"]
                                stringByAppendingPathComponent:@"screen"];
        NSSet *screenSet = [NSSet setWithArray:
            [NSFileManager.defaultManager contentsOfDirectoryAtPath:screenDir
                                                              error:nil] ?: @[]];

        __block NSUInteger total = 0, valid = 0, invalid = 0, captured = 0;
        [contents enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
            NSString *trimmed = [line stringByTrimmingCharactersInSet:
                                 NSCharacterSet.whitespaceCharacterSet];
            if (trimmed.length == 0) return;
            total++;
            NSData *data = [trimmed dataUsingEncoding:NSUTF8StringEncoding];
            NSError *jerr = nil;
            id obj = [NSJSONSerialization JSONObjectWithData:data
                                                      options:0
                                                        error:&jerr];
            if (jerr || ![obj isKindOfClass:NSDictionary.class]) {
                invalid++;
                return;
            }
            NSDictionary *rec = obj;
            if (![rec[@"sfen"] isKindOfClass:NSString.class] ||
                ![rec[@"hash"] isKindOfClass:NSString.class]) {
                invalid++;
                return;
            }
            valid++;
            NSString *fileName = [rec[@"hash"] stringByAppendingString:@".png"];
            if ([screenSet containsObject:fileName]) captured++;
        }];

        dispatch_async(dispatch_get_main_queue(), ^{
            self.totalCount    = total;
            self.validCount    = valid;
            self.invalidCount  = invalid;
            self.capturedCount = captured;
            NSUInteger remaining = valid > captured ? valid - captured : 0;
            self.statusMessage = [NSString stringWithFormat:
                                  @"Idle (%lu remaining / %lu valid)",
                                  (unsigned long)remaining,
                                  (unsigned long)valid];
            [self.tableView reloadData];
            IPALog([NSString stringWithFormat:
                      @"[sheet] validated %@: total=%lu valid=%lu invalid=%lu captured=%lu remaining=%lu",
                      path.lastPathComponent,
                      (unsigned long)total,
                      (unsigned long)valid,
                      (unsigned long)invalid,
                      (unsigned long)captured,
                      (unsigned long)remaining]);
        });
    });
}

// ---------------------------------------------------------------------------
// Smoke test — one-shot proof-of-life for the runner's dependency chain.
// Reads the parseSFEN trampoline, reads the Position slot, applies a
// hardcoded starting-position SFEN, snapshots the app's key window, and
// PNG-writes to Documents/piyo_smoke.png. Every step logs so the on-
// device log tells us exactly which step (if any) failed.
// ---------------------------------------------------------------------------

- (void)startBatch {
    if (!self.loadedPath) {
        self.statusMessage = @"No JSONL selected";
        [self.tableView reloadData];
        return;
    }
    if ([PiyoBatchRunner isRunning]) {
        self.statusMessage = @"Already running";
        [self.tableView reloadData];
        return;
    }

    self.running = YES;
    self.statusMessage = @"Starting batch…";
    [self.tableView reloadData];

    // Dismiss the sheet first so PiyoShogi has the whole screen back
    // for its navigation animation. animated:NO keeps the batch start
    // instant — waiting on the sheet-dismiss animation before the first
    // paste is exactly the "weird delay" the earlier tuning cut.
    NSString *path = self.loadedPath;
    [self dismissViewControllerAnimated:NO completion:^{
        [PiyoBatchRunner startWithJsonlPath:path];
    }];
}

- (void)dismissSheet {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
