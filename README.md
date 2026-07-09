<h1 align="center">PiyoShot</h1>

<p align="center">
  <img src="icon.webp" alt="PiyoShot icon" width="180" />
</p>

<p align="center">
  <em>SFEN JSONL から <strong>PiyoShogi</strong> の盤面 PNG をバッチキャプチャする、<br/>
  未脱獄環境向けサイドロード dylib。</em>
</p>

<p align="center">
  <img alt="version" src="https://img.shields.io/badge/version-v0.1.0-2f80ed?style=flat-square" />
  <img alt="targets PiyoShogi" src="https://img.shields.io/badge/targets-PiyoShogi%205.7.5%20(199)-ff66a3?style=flat-square" />
  <img alt="platform" src="https://img.shields.io/badge/platform-iOS%2015.0%E2%80%9316.5-blue?style=flat-square" />
  <img alt="arch" src="https://img.shields.io/badge/arch-arm64%20rootless-555?style=flat-square" />
  <img alt="hook engine" src="https://img.shields.io/badge/hook-Dobby-black?style=flat-square" />
  <img alt="side" src="https://img.shields.io/badge/runs-client--side%20only-1f9d55?style=flat-square" />
  <img alt="status" src="https://img.shields.io/badge/scope-authorized%20research%20only-c69214?style=flat-square" />
</p>

---

PiyoShot は **PiyoShogi** に注入するサイドロード dylib で、SFEN の入った
JSONL ファイルを読み込み、1 局面ずつ `parseSFEN` に流し込んで
`ShogiBoardView` を再描画し、盤面の PNG を端末内 Documents 配下に
書き出す。OCR 教師データ生成などの調査用途に、**未脱獄** (TrollStore /
AltStore / SideStore 再署名) で 30,000 件級のバッチをこなすことを目的にしている。

IPA-Patch の共通 `shared/` ツールチェイン (binpatch レシピ、
`build_patched_ipa.sh`) をベースに、Substrate ではなく **Dobby** を
インラインフックエンジンとして使い、UI は透明 UIWindow + コーナー
スワイプで presented される `UISheetPresentationController` にまとめている。

### Client-side only

PiyoShot が扱うのはあくまで **アプリのプロセス内メモリ** と **端末内ファイル**
だけ。tweak は次のことをしない:

- PiyoShogi のサーバへリクエストを組み立てて送る、
- キャプチャ済みリクエストをリプレイする、
- ネットワーク経路を proxy / MITM する、
- アカウントに紐づくデータやサーバ状態を書き換える。

すべての hook を off にしてアプリを再起動すれば、素の PiyoShogi に戻る。

## 機能

corner swipe (右下 → 左上) で開く Sheet 上に、以下の UI を並べる。

| コンポーネント | 内容 |
|---|---|
| **JSONL ファイル選択** | `UIDocumentPickerViewController` で SFEN + hash の JSONL を選ぶ。ファイルは Documents 配下にコピーされる (再開のため)。 |
| **総件数 / 完了 / スキップ** | 現在の進捗を数値表示。 |
| **進捗バー** | 0.0 – 1.0。 |
| **撮影対象トグル** | `盤面のみ` / `画面全体` / `両方` を切り替え。 |
| **開始 / キャンセル** | バッチ実行の制御。キャンセルは atomic BOOL で次ループ先頭に伝わる。 |
| **現在の SFEN** | 処理中の SFEN 先頭 40 文字を表示。 |
| **出力パス** | `Documents/piyo_captures/` を表示。 |

内部ではさらに以下の hook が常時走る。

| Hook | 対象 | 効果 |
|---|---|---|
| **Validator bypass** | `validator @ 0x41270` | 局面バリデータを強制 `return 1`。合法性チェックを飛ばして任意 SFEN を反映できる。 |
| **parseSFEN trampoline** | `parseSFEN @ 0x43704` | Swift internal symbol を Dobby の trampoline 経由で callable にし、バッチ側から `orig_parse_sfen(pos, sfen)` として叩けるようにする。hook 側は pass-through。 |
| **Position slot 読み取り** | `base + 0xf505d8` (`Position**`) | drawRect が参照する Position ダブルポインタ。バッチが `current_position()` として読む。 |

## 入出力仕様

### 入力 JSONL

```jsonl
{"sfen": "lnsgkgsnl/1r5b1/ppppppppp/9/9/9/PPPPPPPPP/1B5R1/LNSGKGSNL b - 1", "hash": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"}
{"sfen": "7l1/5+P1kl/4p1ng1/pr1p2spp/1p7/...", "hash": "..."}
```

- `hash`: 呼び出し側で計算済みの SHA-256 hex (64 文字)。dylib 側では再計算しない。
- 1 行 1 レコード / UTF-8 / 改行区切り。
- メモリに全部載せず `NSInputStream` の逐次読みで捌く。30k 件想定。

### 出力

```
Documents/
├── piyo_captures/
│   ├── <hash>_board.png       # ShogiBoardView 単体スナップ
│   ├── <hash>_screen.png      # key window 全体スナップ
│   └── _manifest.jsonl        # 各件の結果 + timestamp + design ID
├── piyo_input_<yyyymmdd_hhmmss>.jsonl   # 入力の再開用コピー
└── piyocap.log                # NSLog ミラー
```

- 同名 PNG が既に存在すれば skip → 途中で kill しても再実行で続きから走る。
- `Info.plist` に `UIFileSharingEnabled` / `LSSupportsOpeningDocumentsInPlace` を
  注入することで、Files アプリの「このiPhone内 → PiyoShogi」から取り出せる。

## 互換性

| | |
|---|---|
| **PiyoShogi 版** | `5.7.5` (`CFBundleVersion` 199) |
| **iOS** | 15.0 – 16.5, arm64. iOS 17+ は Dobby の PAC 対応状況によるので P0 段階で追試。 |

すべての hook はこの PiyoShogi ビルドの `PiyoShogi` バイナリに対する RVA に
固定されている。バージョンが変わると RVA がドリフトして tweak は silent
no-op か最悪クラッシュするので、**RVA を再導出しないまま別バージョンに
注入しない**。

## Versioning

PiyoShot は **独自の [SemVer](https://semver.org/)** を持つ。ホストアプリの
PiyoShogi 側バージョンとは数字を共有しない。

| フィールド | 意味 |
|---|---|
| `MAJOR` | Sheet UI のレイアウト、JSONL スキーマ、配布形態などの破壊的変更。 |
| `MINOR` | 新しい hook、新しい Sheet ウィジェット、新しい撮影モード。 |
| `PATCH` | クラッシュ / 挙動修正など、外向き挙動を変えない fix。 |

**対象 PiyoShogi 版** は [互換性](#互換性) の表に固定され、更新のたびに
RVA を再導出してから PATCH / MINOR として出す。ホストが上がっただけで
MAJOR は上げない。

タグ `vMAJOR.MINOR.PATCH` を打つと `deployment` ワークフローが走り、
[`CHANGELOG.md`](CHANGELOG.md) の該当セクションをリリースノートに載せて
成果物を GitHub Releases に上げる。dylib には build 時の short git commit
を埋め込み、Sheet の About セクションに表示するので、配布後の dylib から
ビルド元コミットが逆引きできる。

## Requirements

- [Theos](https://theos.dev/) (`$THEOS` が通っていること)。PiyoShot は
  pure Objective-C++ (`.mm`) で書かれていて Orion ランタイムには依存しない。
- iOS 15.0 – 16.5, arm64。
- **Dobby** を `vendor/dobby/` に置く (submodule)。static link で組み込む。
- Patched IPA 経路を使う場合は、復号済みの PiyoShogi `.ipa` (`assets/` 配下)。

## Build

### Jailbroken (rootless)

Dopamine / palera1n / unc0ver / checkra1n など向け。`.deb` を作って
`/var/jb/Library/MobileSubstrate/DynamicLibraries/` に配置し、
MobileSubstrate の `MSHookFunction` で hook する。

```sh
make package
# SSH で流し込むなら
make package install THEOS_DEVICE_IP=<device-ip>
```

### Jailed dylib (TrollStore)

TrollStore が使える端末向け。Dobby を static link した bare dylib を吐く
ので、外部の hook engine 依存を持たずに TrollStore 経由でクリーンに
注入できる。

```sh
make jailed
# -> packages/jailed/PiyoShot.dylib
```

インストール手順:

1. `make jailed` で dylib を作る。
2. `packages/jailed/PiyoShot.dylib` を復号済み PiyoShogi `.app` の
   `Frameworks/` に置き、`LC_LOAD_DYLIB` を注入する (または `.ipa` に
   包み直す)。
3. できた `.ipa` を TrollStore に流し込む。

TrollStore の使えない端末では、下の Patched IPA 経路を使う。同じ hook
ロジックだが、hook 実装が `__DATA` 経由の cave entry を通るので
Sideloadly / AltStore / SideStore でもクリーンに動く。

### Patched IPA (TrollStore / Sideloadly / AltStore / SideStore)

もっともポータブルな配布経路。非脱獄環境ならほぼ何でも通る。

静的に `PiyoShogi` バイナリを書き換えて、各 hook site から `__TEXT` cave に
BL させ、その cave が `__DATA,__bss` のスロットテーブル経由で dylib を
呼ぶ形にする。dylib 側は `__DATA` にしか書き込まないので、iOS 18 の
Code Signing Monitor にも刺さらない。

```sh
mkdir -p assets
cp ~/Downloads/PiyoShogi-5.7.5.ipa assets/   # 復号済み IPA を自前で用意
make ipa
# -> packages/binpatch/PiyoShot.dylib
# -> packages/ipa/PiyoShot-binpatch.ipa
```

できた `PiyoShot-binpatch.ipa` は、TrollStore, Sideloadly, AltStore,
SideStore, または Apple Developer Program の証明書での署名 + Xcode
インストールのいずれでも動く。dylib は `LC_LOAD_DYLIB` で既に配線
済みなので、追加の insert 作業は不要。

RVA / prologue のドリフトチェックはコミット前に:

```sh
PYTHONPATH=shared:. python3 -m tools.verify_sites \
  --recipe recipes.piyoshot \
  --index assets/dump.cs.index.json \
  --ipa   assets/PiyoShogi-5.7.5.ipa
```

これで recipe 側 `_SITES` の RVA + prologue が dump / IPA と一致するかを
チェックできる。`make ipa` の前に必ず通しておく。

### Releases

タグ付きバージョンの成果物は GitHub Releases に上がる。各リリースは:

| ファイル | 用途 |
|---|---|
| `work.tkgstrator.piyoshot_<ver>_iphoneos-arm64.deb` | 脱獄端末 (Dopamine / palera1n / unc0ver / checkra1n) 向け。rootless。`dpkg -i` で入る。 |
| `work.tkgstrator.piyoshot_<ver>_iphoneos-arm64-jailed.dylib` | TrollStore 向け。復号済み IPA に注入する。 |
| `work.tkgstrator.piyoshot_<ver>_iphoneos-arm64-binpatch.dylib` | Patched IPA 経路の dylib 単体。TrollStore / Sideloadly / AltStore / SideStore / Apple Developer Program のいずれとも組める。 |
| `SHA256SUMS` | `sha256sum -c SHA256SUMS` で検証する用。 |

**Patched IPA そのものはリリースしない** — 復号済みホストアプリの
再配布は不可能なので、operator 側で自前の `assets/PiyoShogi-5.7.5.ipa` に
対して `make ipa` を叩いてもらう形になる。

## Documentation

計画・設計は [`docs/`](docs/) 配下:

- [`docs/plans/piyoshogi_sideload_capture.md`](docs/plans/piyoshogi_sideload_capture.md)
  — プロジェクト計画書。目的 / スコープ / 制約 / マイルストーン / リスク。
- [`docs/spec/piyoshogi_sideload_capture.md`](docs/spec/piyoshogi_sideload_capture.md)
  — dylib 設計書。モジュール構成 / Dobby hook / Overlay UI / Batch Runner /
  Capture / 状態遷移 / 保存ファイル形式 / Info.plist 差分 / 診断。

移植側 (RVA 更新、site 検証、CSM 対応の binpatch 経路) の共通ツールは
`shared/` submodule (`build_patched_ipa.sh`, `verify_sites.py`,
`patch_macho.py`) に集約されている。IPA-Patch の他プロジェクトと
同じ形状。
