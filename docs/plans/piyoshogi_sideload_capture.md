# PiyoShogi Sideload キャプチャ dylib 計画書

**対象**: PiyoShogi 5.7.5 (build 199) / iOS 15.0–16.5 / arm64 (rootless)
**成果物**: 未脱獄 (TrollStore / AltStore・SideStore 再署名) に注入する `.dylib`
**開発リポジトリ**: 本レポではなく別リポで実装する。本書は仕様・設計の参照資料。

---

## 1. 目的

Netflix プロジェクトから派生した OCR 教師データ生成基盤の一部として、**未脱獄環境でも PiyoShogi の SFEN → 盤面 PNG レンダリングをバッチ実行できる自己完結型 dylib** を作る。

既存の `packages/tweak/PiyoClean/Tweak.x` は脱獄 (Cydia Substrate / MSHookFunction) 前提で組んであり、駆動側は Frida + Python (`packages/piyo-driver/`) で URL scheme か parseSFEN 直叩きしている。これを次のように置き換える。

- **Substrate → Dobby** (インラインフック)
- **Frida driver → 端末内 UI** (下端右スワイプで Sheet)
- **URL scheme / RPC → UIDocumentPicker でファイル選択**
- **配布は開発者不要の Sideload** (TrollStore + 再署名 IPA の両対応)

## 2. スコープ

### やること

1. PiyoShogi プロセスに dylib を注入 (LC_LOAD_DYLIB)
2. アプリ起動後、透明 UIWindow を最上位に貼って画面右下から左上への UISwipeGesture を検出
3. ジェスチャ検出で UIViewController を present、Sheet 内に「JSONL ファイル選択」「進捗表示」「キャンセル」「撮影対象トグル (盤面のみ / 画面全体 / 両方)」を配置
4. UIDocumentPickerViewController で JSONL ファイル (SFEN + hash 30k 件想定) を選択
5. 各エントリで `parseSFEN` (RVA 0x43704) を Dobby でフックした関数経由で叩き、Position を書き換え → ShogiBoardView を redraw → PNG を Documents 配下に保存
6. バリデータ (`validator @ RVA 0x41270`) は PiyoClean 同様に強制 `return 1`
7. バナー広告は既存 collapse ロジックを流用

### やらないこと

- SFEN 生成側 (packed_sfen_value からの層別サンプリング) — `packages/piyo-driver/sample_sfens.py` の責務
- OCR 教師データのラベル貼り
- 撮影済み PNG のリモート転送 (端末内保存のみ、Files アプリ経由で取り出す)
- iOS 17+ 対応 (別途検証)

## 3. 制約と前提

### 3.1 未脱獄注入モデル

| 配布経路 | 注入方法 | 制約 |
|--------|--------|----|
| **TrollStore** | dylib を `.app/Frameworks/` に置き、Info.plist は不要 (TrollStore が自動で `insert_dylib` 相当を実施)。実質 arm64e/rootless で自由 entitlements | iOS 14.0–16.6.1 (+ 17.0 の一部)、TrollStore 未導入端末では使えない |
| **AltStore / SideStore / Sideloadly 再署名** | IPA に対して `insert_dylib` (or `optool install`) で `LC_LOAD_DYLIB` を注入 → Apple Dev cert (7日/1年) で再署名 | 期限切れごとに再インストール。App Groups / iCloud 使用不可。UIDocumentPicker は使える |

**両対応の分岐点**:

- **entitlements** に依存する API は使わない (App Groups なし、URL Scheme 追加なし)
- **保存先** は `NSDocumentDirectory` (Files アプリの「このiPhone内」→ PiyoShogi 配下で見える)
- **hook 実装** は Substrate 系 API を叩かず Dobby (or ellekit の C API) だけを使う

### 3.2 Dobby インラインフック

- Substrate の `MSHookFunction` を **`DobbyHook(void *addr, void *replace, void **orig)`** に置換
- Dobby は arm64 の LDR/BR 命令パッチ + trampoline で `mprotect(RX→RWX→RX)` を実施
- iOS 15/16 rootless 環境で確認済み (SideStore, TrollStore コミュニティ実績あり)
- リンク方法: Dobby を `.a` として fat static link (build.mm 側で `-lDobby`)

### 3.3 UI 差し込みポリシー

- **透明 UIWindow** を `windowLevel = UIWindowLevelAlert + 1000` で常駐
- **UIScreenEdgePanGestureRecognizer** ではなく **corner-hit UISwipeGesture** を使う (screen-edge は Home Indicator/Control Center と衝突)
- 具体: `bottomRight` 100×100pt の隠しビューに `UISwipeGestureRecognizer(direction: .upLeft は非対応)` → `UIPanGestureRecognizer` を張って始点が corner 内かつ移動量 > 60pt で発火
- Sheet は `UIModalPresentationPageSheet` (iOS 15+ の detent は `medium()` / `large()`)

### 3.4 SFEN JSONL 仕様 (入力)

```jsonl
{"sfen": "lnsgkgsnl/1r5b1/ppppppppp/9/9/9/PPPPPPPPP/1B5R1/LNSGKGSNL b - 1", "hash": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"}
{"sfen": "7l1/5+P1kl/4p1ng1/pr1p2spp/1p7/...", "hash": "..."}
```

- `hash` はドライバ側で計算済みの SHA-256 hex (64文字)。dylib 内で再計算しない。
- 1 行 1 レコード。改行区切り。UTF-8。
- 30k 件想定 → メモリに全部乗せずに `NSInputStream` + `NSJSONSerialization` の行単位読みで処理

### 3.5 出力

- 保存先: `<app sandbox>/Documents/piyo_captures/`
- ファイル名:
  - 盤面のみ: `<hash>_board.png`
  - 画面全体: `<hash>_screen.png`
- 同名ファイルが既にあれば skip (再開時に前回結果を捨てない)
- バッチ完了時に `_manifest.jsonl` を追記出力 (処理結果 + タイムスタンプ + design ID)

## 4. アーキテクチャ概要

```
┌──────────────────────────────────────────────────────────┐
│ PiyoShogi.app (プロセス)                                   │
│                                                          │
│  ┌────────────────────┐   ┌───────────────────────────┐   │
│  │  PiyoShogi 本体     │   │  PiyoCap.dylib (本 tweak) │   │
│  │  - VCMainView       │   │                          │   │
│  │  - ShogiBoardView   │◄──┤  [Dobby hooks]           │   │
│  │  - parseSFEN 0x437  │   │   - validator @ 0x41270  │   │
│  │  - validator 0x412  │   │   - parseSFEN @ 0x43704  │   │
│  │                     │   │                          │   │
│  │                     │   │  [ObjC swizzle]          │   │
│  │                     │   │   - VCMainView.viewDidLoad│  │
│  │                     │   │   - GADBannerView loadReq │  │
│  │                     │◄──┤                          │   │
│  │                     │   │  [Overlay UI]            │   │
│  │                     │   │   - Transparent UIWindow │   │
│  │                     │   │   - Corner swipe detect  │   │
│  │                     │   │   - SheetVC              │   │
│  │                     │   │   - UIDocumentPicker     │   │
│  │                     │   │   - Batch runner (queue) │   │
│  └────────────────────┘   └───────────────────────────┘   │
│                                                          │
│  Documents/piyo_captures/<hash>_board.png etc.           │
└──────────────────────────────────────────────────────────┘
```

## 5. マイルストーン

| Phase | 目標 | 成功判定 |
|------|------|--------|
| **P0: 注入 PoC** | 空の dylib を PiyoShogi に load、`%ctor` で `NSLog` | Console.app に "PiyoCap loaded" |
| **P1: Dobby バリデータ bypass** | RVA 0x41270 を Dobby で hook して return 1 | 非合法 SFEN を URL scheme で流して盤面反映される |
| **P2: Overlay UI** | 透明 UIWindow + corner swipe → Sheet 表示 | 実機で右下 → 左上スワイプで Sheet が出る |
| **P3: JSONL 選択 + パース** | UIDocumentPicker で JSONL 選択 → 件数表示 | Sheet に「30000 件検出」 |
| **P4: parseSFEN 直叩き** | 1 件 SFEN を parseSFEN に流す → 盤面変わる | 目視で 3〜5 局面順送りできる |
| **P5: バッチ + PNG 保存** | 全件処理して Documents に PNG 吐く | 30000 件処理完了。Files アプリで確認 |
| **P6: 撮影対象トグル** | Sheet で board / screen / both を切り替え | 選択に応じて出力ファイルが変わる |
| **P7: 進捗・キャンセル・再開** | 進捗バー、キャンセルボタン、既存ファイル skip | 途中で kill → 再実行で続きから |

## 6. リスクと対策

| リスク | 影響 | 対策 |
|------|-----|-----|
| Dobby の inline hook が iOS 16.5+ の PAC で失敗 | validator/parseSFEN が hook できず全滅 | Dobby 最新版 (PAC対応) を使う。ダメなら `hook_piyoshogi_paste.js` 経路 (btnKifPasteClicked を swizzle) にフォールバック |
| parseSFEN が Position 初期化前に呼ばれてクラッシュ | 起動直後の撮影失敗 | Frida fastcapture と同じく、初回は URL scheme (piyoshogi://?sfen=…) を自分で `[UIApplication openURL:]` して VCMainView を立ち上げてから batch 開始 |
| ShogiBoardView が Sheet に隠れて描画されない | PNG が真っ黒 or Sheet 越しに撮れる | 撮影前に Sheet を一時 `dismissViewControllerAnimated:NO`、撮影後に再 present。または Sheet を最初から半透明で回避 |
| 30000 件で drawRect が追いつかず drop | 一部欠損 | main queue で 1 件ずつ完了待ち (Frida fastcapture の busy-wait 方式を移植)、estimate 1件 50–100ms → 30k で 25–50 分 |
| 再署名 IPA で `LC_LOAD_DYLIB` の rpath が壊れる | dylib load 失敗 | dylib install_name を `@executable_path/Frameworks/PiyoCap.dylib` に固定、`insert_dylib` は必ず `--inplace` + `--all-yes` |
| 撮影中に Auto-Lock/バックグラウンド遷移 | drawRect が止まって進捗停止 | `[UIApplication setIdleTimerDisabled:YES]` を batch 開始時にセット、終了で戻す |
| Files アプリで PNG が見えない | 取り出せない | `Info.plist` に `UISupportsDocumentBrowser=YES` + `LSSupportsOpeningDocumentsInPlace=YES` を注入 (再署名時 or TrollStore Info.plist 上書き) |

## 7. 参照実装

**必読** (実装移植元):

- `packages/tweak/PiyoClean/Tweak.x` — validator/parser hook、駒デザイン override、do_capture 全部
- `packages/frida/hook_piyoshogi_fastcapture.js` — Position slot 直叩きバッチ、CGBitmapContext 経由の snapshot
- `packages/frida/hook_piyoshogi_paste.js` — フォールバック経路 (btnKifPasteClicked)
- `packages/piyo-driver/fastcapture.py` — バッチドライバのフロー参考

**RVA 定数** (全て PiyoShogi 5.7.5 build 199 arm64):

- `validator`: `0x41270` — 局面バリデータ (return 1 固定で bypass)
- `parseSFEN`: `0x43704` — `(Position*, const char *sfen) -> int`
- `Position` slot: `base + 0xf505d8` — `Position**` (drawRect が読む globe)

## 8. 次のステップ

1. 本書を承認 → 設計書 `docs/spec/piyoshogi_sideload_capture.md` を確定
2. 別リポで theos プロジェクト初期化 (`$THEOS/bin/nic.pl` → tweak テンプレでなく dylib テンプレを選択)
3. Dobby を submodule で追加 → static link 設定
4. P0 の PoC を通して注入経路 (TrollStore + 再署名 IPA) を両方確認
5. 以降 P1 → P7 を順に
