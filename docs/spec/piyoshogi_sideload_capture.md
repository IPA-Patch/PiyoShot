# PiyoShogi Sideload キャプチャ dylib 設計書

**対象バージョン**: PiyoShogi 5.7.5 (build 199) / iOS 15.0–16.5 arm64 rootless
**関連文書**: `docs/plans/piyoshogi_sideload_capture.md`

---

## 1. モジュール構成

theos の `dylib` テンプレート (`iphone/library`) をベースに、以下のファイル構成で組む。

```
PiyoCap/
├── Makefile
├── control                 # deb メタ (TrollStore/deb 配布用)
├── PiyoCap.h
├── PiyoCap.mm              # %ctor + hook 束ね
├── PiyoHooks.mm            # Dobby hooks (validator / parseSFEN)
├── PiyoSwizzle.mm          # ObjC method_exchangeImplementations
├── PiyoOverlay.mm          # 透明 UIWindow + corner-swipe 検出
├── PiyoSheetVC.mm          # UIViewController (Sheet 中身)
├── PiyoBatchRunner.mm      # JSONL 逐次処理 + PNG 保存
├── PiyoCapture.mm          # ShogiBoardView / key window snapshot
├── PiyoLog.h/.mm           # NSLog + Documents/piyocap.log ミラー
├── vendor/
│   └── Dobby/              # submodule
└── layout/                 # TrollStore 用 payload レイアウト
```

`.mm` にするのは Dobby の C++ header を混ぜるため。ObjC++ で通す。

## 2. 注入と初期化

### 2.1 dylib 側

- **install_name**: `@executable_path/Frameworks/PiyoCap.dylib`
- **リンク**: `-framework UIKit -framework Foundation -framework CoreGraphics -framework QuartzCore -lDobby -lc++`
- **エントリ**: `__attribute__((constructor))` の `piyocap_init()`
  - `Dobby` の hook 登録
  - `NSNotificationCenter` に `UIApplicationDidFinishLaunchingNotification` observer 登録 (この時点で UIWindow 作るとまだ scene が無い)
  - observer 側で PiyoOverlay を初期化

具体形:

```objc
// PiyoCap.mm
static void piyocap_did_finish_launching(NSNotification *note) {
    (void)note;
    dispatch_async(dispatch_get_main_queue(), ^{
        [PiyoOverlay.shared installOnActiveScene];
    });
}

__attribute__((constructor))
static void piyocap_init(void) {
    @autoreleasepool {
        piyo_log(@"PiyoCap loaded (5.7.5 / build 199)");
        install_validator_hook();
        install_parse_sfen_hook();
        install_swizzles();               // GAD banner no-op 等
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *n) {
            piyocap_did_finish_launching(n);
        }];
        piyo_log(@"PiyoCap installed");
    }
}
```

### 2.2 TrollStore 配布 (Payload)

TrollStore は `.tipa` / `.ipa` を受け取り、内部で `LC_LOAD_DYLIB` を注入して再インストールする。dylib を `Payload/PiyoShogi.app/Frameworks/PiyoCap.dylib` に置いておけば、TrollStore の "Enable Tweak Injection" フラグで自動 load される。

### 2.3 AltStore/SideStore 再署名 (Payload)

Makefile に `stage::` フックで以下を実行するタスクを組む。

```makefile
stage::
	@insert_dylib --inplace --all-yes \
		'@executable_path/Frameworks/PiyoCap.dylib' \
		'$(THEOS_STAGING_DIR)/Applications/PiyoShogi.app/PiyoShogi'
	@mkdir -p '$(THEOS_STAGING_DIR)/Applications/PiyoShogi.app/Frameworks'
	@cp '$(THEOS_OBJ_DIR)/PiyoCap.dylib' \
		'$(THEOS_STAGING_DIR)/Applications/PiyoShogi.app/Frameworks/'
```

その後 `zsign` (or `AltStore` の自動再署名) を通す。

## 3. Dobby フック

### 3.1 バリデータ

```objc
typedef uint64_t (*validator_fn)(uint64_t, uint64_t, uint64_t, uint64_t,
                                 uint64_t, uint64_t, uint64_t, uint64_t);
static validator_fn orig_validator = NULL;

static uint64_t my_validator(uint64_t a0, uint64_t a1, ...) {
    if (orig_validator) (void)orig_validator(a0, a1, ...);   // side effect
    return 1;
}

void install_validator_hook(void) {
    void *base = find_piyoshogi_header();  // dyld API
    void *target = (uint8_t *)base + 0x41270;
    DobbyHook(target, (void *)my_validator, (void **)&orig_validator);
}
```

`MSHookFunction` からの機械的置換。`find_piyoshogi_header()` は `_dyld_image_count()` を回して `strstr(name, "/PiyoShogi.app/PiyoShogi")` で該当ヘッダを返す (PiyoClean と同一)。

```objc
#include <mach-o/dyld.h>

static const struct mach_header *find_piyoshogi_header(void) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "/PiyoShogi.app/PiyoShogi")) {
            return _dyld_get_image_header(i);
        }
    }
    return NULL;
}
```

### 3.2 parseSFEN

同じパターン。ただし本 tweak では自前で `parseSFEN` を **呼びに行く** ので、`orig_parse_sfen` は callable として保持し、hook 側では pending name の消費ロジックは持たない (URL scheme 経由の消費は不要になった)。

```objc
typedef int32_t (*parse_sfen_fn)(void *pos, const char *sfen);
static parse_sfen_fn orig_parse_sfen = NULL;

void install_parse_sfen_hook(void) {
    void *target = (uint8_t *)find_piyoshogi_header() + 0x43704;
    DobbyHook(target, (void *)my_parse_sfen, (void **)&orig_parse_sfen);
}

static int32_t my_parse_sfen(void *pos, const char *sfen) {
    return orig_parse_sfen(pos, sfen);   // 本 tweak では pass-through で十分
}
```

**なぜ hook を張るか**: `orig_parse_sfen` を関数ポインタとして取り出す唯一の手段。直接 `dlsym` できない Swift internal symbol なので、Dobby の trampoline 経由で呼び出せるようにする。

### 3.3 Position slot 読み取り

```objc
void *get_position_slot(void) {
    return (uint8_t *)find_piyoshogi_header() + 0xf505d8;   // Position**
}

void *current_position(void) {
    return *(void **)get_position_slot();
}
```

初回 `orig_parse_sfen(nil, sfen)` を叩くと nullptr でクラッシュするので、**バッチ開始前に必ず URL scheme を 1 発叩いて VCMainView + Position 初期化を済ませる** (P5)。

## 4. Overlay UI

### 4.1 透明 UIWindow

`UIApplicationDidBecomeActiveNotification` で lazily 初期化。

```objc
@interface PiyoOverlayWindow : UIWindow @end

@implementation PiyoOverlayWindow
- (BOOL)pointInside:(CGPoint)p withEvent:(UIEvent *)event {
    // 右下 corner の隠しトリガ領域だけ hit-test を通す
    CGRect corner = CGRectMake(self.bounds.size.width  - 100,
                               self.bounds.size.height - 100, 100, 100);
    return CGRectContainsPoint(corner, p);
}
@end
```

hit-test で右下 100×100 だけ hit させることで、それ以外の操作はアプリ本体に透過する。

`windowLevel = UIWindowLevelAlert + 1000` で最前面に。

### 4.2 コーナースワイプ検出

`UIScreenEdgePan` は Home Indicator と衝突するので **UIPanGestureRecognizer** で自前判定。

```objc
- (void)handlePan:(UIPanGestureRecognizer *)gr {
    if (gr.state == UIGestureRecognizerStateBegan) {
        _startPoint = [gr locationInView:gr.view];
    } else if (gr.state == UIGestureRecognizerStateChanged) {
        CGPoint p = [gr locationInView:gr.view];
        CGFloat dx = _startPoint.x - p.x;
        CGFloat dy = _startPoint.y - p.y;
        if (dx > 60 && dy > 60 && !_presented) {
            _presented = YES;
            [self presentSheet];
        }
    } else if (gr.state == UIGestureRecognizerStateEnded ||
               gr.state == UIGestureRecognizerStateCancelled) {
        _presented = NO;
    }
}
```

`_presented` フラグでダブル発火抑止。

### 4.3 Sheet 表示

```objc
- (void)presentSheet {
    PiyoSheetVC *vc = [[PiyoSheetVC alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *pc = nav.sheetPresentationController;
        pc.detents = @[[UISheetPresentationControllerDetent mediumDetent],
                        [UISheetPresentationControllerDetent largeDetent]];
        pc.prefersGrabberVisible = YES;
    }
    UIViewController *root = find_top_view_controller();
    [root presentViewController:nav animated:YES completion:nil];
}
```

`find_top_view_controller()` は key window の rootViewController から `presentedViewController` を辿って最上位まで。

```objc
// PiyoCapture.mm — ビュー探索ヘルパー (PiyoClean から流用)
UIView *find_board_view(UIView *root) {
    if (!root) return nil;
    NSString *cls = NSStringFromClass([root class]);
    if ([cls containsString:@"ShogiBoardView"] ||
        [cls containsString:@"EditBoardView"]) return root;
    for (UIView *sub in root.subviews) {
        UIView *r = find_board_view(sub);
        if (r) return r;
    }
    return nil;
}

UIWindow *find_key_window(void) {
    UIApplication *app = UIApplication.sharedApplication;
    UIWindow *fallback = nil;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) return w;
            if (!fallback) fallback = w;
        }
    }
    return fallback;
}

UIViewController *find_top_view_controller(void) {
    UIViewController *vc = find_key_window().rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}
```

## 5. PiyoSheetVC

### 5.1 UI 要素

| コンポーネント | 内容 |
|------------|-----|
| `UIButton` "JSONLファイルを選ぶ" | UIDocumentPickerViewController(forOpeningContentTypes:) を presnt |
| `UILabel` fileNameLabel | 選択されたファイル名を表示 |
| `UILabel` countLabel | "総件数: 30000 / 完了: 12345 / スキップ: 3" |
| `UIProgressView` progressBar | 0.0 – 1.0 |
| `UISegmentedControl` targetSelector | [盤面のみ / 画面全体 / 両方] |
| `UIButton` "開始" | Batch 実行開始 |
| `UIButton` "キャンセル" | Batch 実行中止 |
| `UILabel` currentSfenLabel | 現在処理中の SFEN (先頭 40 文字) |
| `UILabel` outputPathLabel | 出力ディレクトリのパス |

`UITableView` は使わない (30000 行スクロールは無意味)。

### 5.2 UIDocumentPicker

```objc
UTType *jsonlType = [UTType typeWithFilenameExtension:@"jsonl"];
UTType *txtType   = UTTypePlainText;
UIDocumentPickerViewController *picker =
    [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[jsonlType, txtType]];
picker.delegate = self;
picker.allowsMultipleSelection = NO;
[self presentViewController:picker animated:YES completion:nil];
```

- `didPickDocumentsAtURLs:` で `[url startAccessingSecurityScopedResource]` → ファイルをアプリ Documents 配下にコピーしてから `[url stopAccessingSecurityScopedResource]`
  (bookmark はセッション限定なので、後段 batch 中断・再開のためコピーする)

### 5.3 保存先の可視化

`Info.plist` (再署名時 or TrollStore 上書き) で

```xml
<key>UIFileSharingEnabled</key><true/>
<key>LSSupportsOpeningDocumentsInPlace</key><true/>
```

を注入すると Files アプリの「このiPhone内 → PiyoShogi」で `piyo_captures/` が見える。

## 6. Batch Runner

### 6.1 実行ループ

```objc
- (void)runBatch {
    NSInputStream *in = [NSInputStream inputStreamWithFileAtPath:self.jsonlPath];
    [in open];
    LineReader *r = [[LineReader alloc] initWithStream:in];  // \n 区切り reader

    while (![self isCancelled]) {
        NSString *line = [r nextLine];
        if (!line) break;
        NSError *err = nil;
        NSDictionary *rec = [NSJSONSerialization JSONObjectWithData:
                                [line dataUsingEncoding:NSUTF8StringEncoding]
                                                            options:0
                                                              error:&err];
        NSString *sfen = rec[@"sfen"];
        NSString *hash = rec[@"hash"];
        if (!sfen || !hash) continue;

        NSString *boardOut  = [self boardPngPath:hash];
        NSString *screenOut = [self screenPngPath:hash];
        BOOL wantBoard  = self.captureBoard  && ![NSFileManager.defaultManager fileExistsAtPath:boardOut];
        BOOL wantScreen = self.captureScreen && ![NSFileManager.defaultManager fileExistsAtPath:screenOut];
        if (!wantBoard && !wantScreen) { self.skipped++; [self updateUI]; continue; }

        [self applySfenAndCapture:sfen hash:hash board:wantBoard screen:wantScreen];
        self.done++;
        [self updateUI];
    }
    [in close];
    [self writeManifest];
}
```

- **同期 main queue 待ち**: `applySfenAndCapture:` は内部で `dispatch_semaphore_wait` で main queue 完了を待つ (Frida fastcapture の busy-wait 相当)。
- **Batch は background thread** で回す。UI 更新は毎回 main queue にホップ。
- **キャンセル**: `_cancelled` フラグを atomic BOOL でセット、ループ先頭で確認。

`LineReader` は 30k 件をメモリに全展開せず 1 行ずつ読むための薄いラッパ。

```objc
// LineReader.mm — NSInputStream から \n 区切りで NSString を吐く
@interface LineReader : NSObject
- (instancetype)initWithStream:(NSInputStream *)stream;
- (NSString *)nextLine;   // EOF で nil
@end

@implementation LineReader {
    NSInputStream *_stream;
    NSMutableData *_buf;
    BOOL _eof;
}
- (instancetype)initWithStream:(NSInputStream *)stream {
    if ((self = [super init])) { _stream = stream; _buf = [NSMutableData new]; }
    return self;
}
- (NSString *)nextLine {
    while (!_eof) {
        const uint8_t *bytes = _buf.bytes;
        for (NSUInteger i = 0; i < _buf.length; i++) {
            if (bytes[i] == '\n') {
                NSString *line = [[NSString alloc]
                    initWithBytes:bytes length:i encoding:NSUTF8StringEncoding];
                [_buf replaceBytesInRange:NSMakeRange(0, i + 1)
                                withBytes:NULL length:0];
                return line;
            }
        }
        uint8_t chunk[4096];
        NSInteger n = [_stream read:chunk maxLength:sizeof(chunk)];
        if (n <= 0) { _eof = YES; break; }
        [_buf appendBytes:chunk length:(NSUInteger)n];
    }
    if (_buf.length == 0) return nil;
    NSString *rest = [[NSString alloc]
        initWithData:_buf encoding:NSUTF8StringEncoding];
    _buf.length = 0;
    return rest;
}
@end
```

### 6.2 applySfenAndCapture

```objc
- (void)applySfenAndCapture:(NSString *)sfen
                       hash:(NSString *)hash
                      board:(BOOL)wantBoard
                     screen:(BOOL)wantScreen {
    void *pos = current_position();
    if (!pos) {                          // Position 未初期化
        [self bootstrapMainView];
        pos = current_position();
        if (!pos) return;                // 諦める
    }
    int32_t ok = orig_parse_sfen(pos, sfen.UTF8String);
    if (ok != 1) { self.failed++; return; }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        // Sheet を一時的に隠す (盤面が見えないと board 撮影で真っ黒)
        [self.presentedSheet dismissViewControllerAnimated:NO completion:nil];

        UIView *board = find_board_view(find_key_window());
        [board setNeedsDisplay];
        [board.layer displayIfNeeded];
        [board layoutIfNeeded];

        if (wantBoard && board) {
            NSData *png = snapshot_view_as_png(board);
            [png writeToFile:[self boardPngPath:hash] atomically:YES];
        }
        if (wantScreen) {
            UIView *root = find_key_window();
            NSData *png = snapshot_view_as_png(root);
            [png writeToFile:[self screenPngPath:hash] atomically:YES];
        }

        // Sheet 再表示 (次の redraw 前に)
        [self representSheet];
        dispatch_semaphore_signal(sem);
    });
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
}
```

**Sheet dismiss/re-present は毎フレームやるとチラつく** → 実装は次のいずれかに寄せる:

- **A**: Sheet の背景 `UIViewController` を transparent (`view.backgroundColor = clearColor`, `modalPresentationStyle = overFullScreen`) にして、盤面が Sheet 越しに常に見える構造にする → dismiss 不要
- **B**: Batch 開始時に一度 dismiss して、進捗表示は Overlay Window 内の非モーダルバナーに切り替える

**推奨**: **A**。UISheetPresentationController は下 3 分の 1 だけ塞ぐので盤面 (画面上部) は基本見える。

推奨 A の実体：

```objc
// PiyoOverlay.mm 側の presentSheet に差し込む
- (void)presentSheet {
    PiyoSheetVC *vc = [PiyoSheetVC new];
    UINavigationController *nav =
        [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationOverFullScreen;   // ← A
    nav.view.backgroundColor = UIColor.clearColor;
    vc.view.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.35];
    // Sheet の "紙" 部分だけ半透明のスクリム、下側 3 分の 2 を空けて盤面を透かす
    [find_top_view_controller() presentViewController:nav animated:YES
                                           completion:nil];
}
```

### 6.3 bootstrapMainView

初回 Position 未初期化対策。`[UIApplication.sharedApplication openURL:]` で `piyoshogi://?sfen=lnsgkgsnl/1r5b1/ppppppppp/9/9/9/PPPPPPPPP/1B5R1/LNSGKGSNL b - 1&num=0` を叩く。VCMainView が押し上げられて Position が初期化される。1 回だけ実行。

## 7. Capture

### 7.1 snapshot_view_as_png

Frida fastcapture の CGBitmapContext 経路をそのまま Objective-C に移植。

```objc
NSData *snapshot_view_as_png(UIView *v) {
    CGSize sz = v.bounds.size;
    if (sz.width <= 0 || sz.height <= 0) return nil;

    // afterScreenUpdates:YES 経路 (PiyoClean 実績)
    UIGraphicsBeginImageContextWithOptions(sz, NO, 0.0);
    BOOL ok = [v drawViewHierarchyInRect:v.bounds afterScreenUpdates:YES];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (!ok || !img) return nil;
    return UIImagePNGRepresentation(img);
}
```

`renderInContext:` 版 (Frida の CGBitmap 経路) はサブレイヤーが飛ぶことがあるので `drawViewHierarchyInRect:` を優先。ただし key window 全体を撮る場合は Status Bar が真っ黒になる既知問題があるので、その時だけ CGBitmap 経路に切り替える。

## 8. 状態遷移

```
[起動] → [ctor] → [ApplicationDidFinishLaunching] → [Overlay 初期化]
                                                        │
                                                        ▼
[Overlay 待機] ◄──────────────────────── [Sheet dismiss]
       │
       │ 右下 → 左上 corner swipe
       ▼
[Sheet 表示 (idle)]
       │
       │ [ファイル選択]
       ▼
[Sheet 表示 (loaded, idle)]
       │
       │ [開始]
       ▼
[Batch 実行中]
       │  ├── [キャンセル] ────► [Sheet 表示 (loaded, idle)]
       │  ├── [完了] ────────► [Sheet 表示 (done)]
       │  └── [エラー]
       ▼
[manifest 書き出し]
```

## 9. 保存されるファイル一覧

```
Documents/
├── piyo_captures/
│   ├── <hash>_board.png
│   ├── <hash>_screen.png
│   └── _manifest.jsonl
├── piyo_input_<yyyymmdd_hhmmss>.jsonl   # 入力を batch 開始時にコピーしたもの
└── piyocap.log                          # NSLog ミラー
```

`_manifest.jsonl` の 1 行例:

```json
{"hash":"e3b0...","sfen":"lnsg.../1B5R1/LNSGKGSNL b - 1","board":true,"screen":true,"design":0,"ts":"2026-07-08T12:34:56Z","parse_ok":1}
```

## 10. Makefile / ビルドと再署名

### 10.1 Makefile 骨格

```makefile
# PiyoCap/Makefile
export ARCHS = arm64
export TARGET = iphone:clang:16.5:15.0
export THEOS_PACKAGE_SCHEME = rootless

INSTALL_TARGET_PROCESSES = PiyoShogi

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = PiyoCap

PiyoCap_FILES = PiyoCap.mm PiyoHooks.mm PiyoSwizzle.mm \
                PiyoOverlay.mm PiyoSheetVC.mm \
                PiyoBatchRunner.mm PiyoCapture.mm \
                PiyoLog.mm LineReader.mm
PiyoCap_CFLAGS   = -fobjc-arc -Ivendor/Dobby/include
PiyoCap_CCFLAGS  = -std=c++17
PiyoCap_LDFLAGS  = -Lvendor/Dobby/lib -lDobby
PiyoCap_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore UniformTypeIdentifiers
PiyoCap_INSTALL_PATH = /Library/Frameworks

include $(THEOS_MAKE_PATH)/library.mk

# AltStore / SideStore 用: staging に IPA を組み立てて再署名するフック
IPA_STAGING = $(THEOS_STAGING_DIR)/ipa
PIYOSHOGI_IPA ?= $(HOME)/piyoshogi_original.ipa

resign: all
	@rm -rf $(IPA_STAGING) && mkdir -p $(IPA_STAGING)
	@unzip -q $(PIYOSHOGI_IPA) -d $(IPA_STAGING)
	@mkdir -p $(IPA_STAGING)/Payload/PiyoShogi.app/Frameworks
	@cp $(THEOS_OBJ_DIR)/PiyoCap.dylib \
	    $(IPA_STAGING)/Payload/PiyoShogi.app/Frameworks/
	@insert_dylib --inplace --all-yes \
	    '@executable_path/Frameworks/PiyoCap.dylib' \
	    $(IPA_STAGING)/Payload/PiyoShogi.app/PiyoShogi
	@zsign -k signing/cert.p12 -m signing/profile.mobileprovision \
	       -p '' -o $(THEOS_STAGING_DIR)/PiyoShogi-piyocap.ipa \
	       $(IPA_STAGING)
	@echo "==> $(THEOS_STAGING_DIR)/PiyoShogi-piyocap.ipa"
```

### 10.2 TrollStore 用 tipa

TrollStore は unsigned で受け付けるので `zsign` は不要。上と同じ手順で `.ipa` を作って `.tipa` にリネームするか、`make package` で TrollStore 側の "Enable Tweak Injection" を使う。

```bash
make -C packages/tweak/PiyoCap package FINALPACKAGE=1
# → .theos/_/ に .deb と .ipa が出る。TrollStore に AirDrop で送るだけ
```

### 10.3 再署名の一発

コマンド単体で使う場合:

```bash
# IPA に dylib を注入して再署名
mkdir -p work && unzip -q PiyoShogi.ipa -d work
mkdir -p work/Payload/PiyoShogi.app/Frameworks
cp PiyoCap.dylib work/Payload/PiyoShogi.app/Frameworks/
insert_dylib --inplace --all-yes \
    '@executable_path/Frameworks/PiyoCap.dylib' \
    work/Payload/PiyoShogi.app/PiyoShogi
zsign -k cert.p12 -m profile.mobileprovision -p '' \
      -o PiyoShogi-piyocap.ipa work
```

## 11. Info.plist 差分

再署名時 or TrollStore Info.plist 上書きで以下を注入。

```xml
<key>UIFileSharingEnabled</key>          <true/>
<key>LSSupportsOpeningDocumentsInPlace</key><true/>
```

他は既存 PiyoShogi の設定をそのまま。URL Scheme は追加しない (Sideload での URL Scheme はホスト衝突リスクあり)。

## 12. デバッグ・診断

- `Documents/piyocap.log` に `NSLog` を tee (`piyo_log()` は PiyoClean と同一形状で移植)
- Sheet に "Debug" セクションを追加、内部状態 (base addr, position slot, orig fn ptr, last parse ret) を表示
- Batch 途中で `piyo_log_flush()` を呼んで即書き
- 実機ログは `docs/CLAUDE.md` に書いてある `ios-hook:device-logs` スキル手順で回収 (SSH 経由 or アプリ内 TCP ログサーバ)

## 13. テストマトリクス

| 端末 | iOS | 配布方式 | 検証項目 |
|-----|----|--------|--------|
| iPhone 12 (arm64e) | 16.5 | TrollStore | P0–P7 全部 |
| iPhone 8 (arm64) | 15.7 | AltStore 再署名 | P0–P7 全部 |
| iPad (M1) | 16.6 | SideStore | P2 の corner swipe (Split View 挙動) |

30000 件バッチは iPhone 12 で **推定 25–50 分**。Auto-Lock 無効化・充電接続前提。

## 14. 未決事項

- iOS 17+ で Dobby の PAC 対応が破綻するケースが報告されている。P0 で iOS 17 端末があれば追試して、失敗するなら計画書 §6 のフォールバック (paste 経路) を実装。
- 駒デザイン切替 (PiyoClean の `g_design_override`) を本 tweak にも入れるか。入れる場合は Sheet に「駒デザイン (0–6 / dark 100–106)」の segmented control を追加、Batch で design × SFEN の cross product で撮る。**まずは MVP に含めず**、P8 として後回し。
