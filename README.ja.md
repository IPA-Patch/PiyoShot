<h1 align="center">PiyoShot</h1>

<p align="center">
  <img src="icon.webp" alt="PiyoShot icon" width="180" />
</p>

<p align="center">
  <em>SFEN の JSONL を食わせて<br/>
  <strong>ぴよ将棋</strong>の盤面をひたすら PNG に落とすやつ。<br/>
  端末内で完結・10 000 件で約 24 分。</em>
</p>

<p align="center">
  <img alt="version" src="https://img.shields.io/badge/version-v0.1.0-2f80ed?style=flat-square" />
  <img alt="targets PiyoShogi" src="https://img.shields.io/badge/targets-PiyoShogi%205.7.5%20(199)-ff66a3?style=flat-square" />
  <img alt="platform" src="https://img.shields.io/badge/platform-iOS%2015.0%E2%80%9326-blue?style=flat-square" />
  <img alt="arch" src="https://img.shields.io/badge/arch-arm64%20rootless-555?style=flat-square" />
  <img alt="runs" src="https://img.shields.io/badge/runs-%E7%AB%AF%E6%9C%AB%E5%86%85%E3%81%A0%E3%81%91-1f9d55?style=flat-square" />
  <img alt="scope" src="https://img.shields.io/badge/scope-%E8%AA%BF%E6%9F%BB%E7%94%A8%E9%80%94%E3%81%AE%E3%81%BF-c69214?style=flat-square" />
</p>

[English README](README.md)

---

**ぴよ将棋（PiyoShogi）** は Studio Ki 提供のオフライン将棋アプリ。
[App Store](https://apps.apple.com/jp/app/id792887995) で配布されている。

PiyoShot はぴよ将棋自身の **「クリップボードから棋譜を貼り付ける」**
フローを自動化する調査用ツール。`{sfen, hash}` の JSONL を 1 行ずつ読み、
ペーストボードにセット → `-[VCTopMenu btnKifPasteClicked:]` を発火 →
新しく解釈された `Position` に対して盤面レイヤーを強制再描画 →
現行キャプチャモードに応じてキーウィンドウ全体または `ShogiBoardView`
のみを `Documents/piyo_capture/{screen,board}/<hash>.png` に PNG 保存する。
生成される画像コーパスは盤面 OCR の学習など、研究用途を想定している。
端末の外には自動で出ていかない。

## 機能

| 機能 | 内容 |
|---|---|
| **JSONL ローダ** | ドキュメントピッカーから `.jsonl`（1 行 `{"sfen": "…", "hash": "…"}`）を選ぶか、deb / IPA に同梱された 10 000 件の既定ファイルを自動読み込み。各行はストリーミング検証されて total / valid / invalid / captured / remaining が並ぶ。 |
| **キャプチャモード** | Segmented Control（**Screen** / **Board**）で保存対象を切替、選択は `NSUserDefaults` に永続化。Screen はキーウィンドウ全体、Board は `ShogiBoardView` サブツリーのみをタイトにクロップして書き出す。各モードは独立した出力ディレクトリとレジューム状態を持つ。 |
| **バッチランナー** | 読み込んだ JSONL を 1 レコードずつイテレート。pasteboard を書いて `btnKifPasteClicked:` を叩き、3 回目の `parseSFEN`（最終の描画準備）が return するのを待ち、`ShogiBoardView` に強制再描画をかけてから `piyo_capture/<mode>/<hash>.png` を PNG 保存する。fire-and-forget、レジューム安全、cancel API は意図的に無い。 |
| **進捗オーバーレイ** | 常時表示の透明 `UIWindow`（Alert レベル）の下中央に `N/total · rate/s · ETA hh:mm` のバナーを描画。放置しながら進捗が一目で分かる。 |
| **ハッシュベース重複排除** | 現行モードの出力ディレクトリを SHA-256 で歩き、内容が完全一致する PNG のグループを一括削除する（バイト単位で被る＝ どちらかのレコードの SFEN が誤っている決定的な証拠。どちらが正しいか判定できないので全部落とす）。ランナーの事前フィルタが次回実行で撮り直す。 |
| **広告非表示** | 常時有効の ObjC ランタイム swizzle。広告 SDK の `-layoutSubviews` をスキップし、load 系メソッドを NoOp 化する — バナーのパルス／フェードが render server を占有しなくなる。iPhone 8 で 1 レコード当たりの実時間が ~350 ms → ~143 ms に落ちるキャプチャ高速化のための最適化。素の見た目には副作用なし。 |

## キャプチャモード

Capture の Segmented Control はサンドボックス内の別々のサブディレクトリへ
書き出し、モード毎に独立したレジューム状態を持つ。

| モード | 出力先 | スナップショット対象 |
|---|---|---|
| **Screen**（既定） | `Documents/piyo_capture/screen/` | キーウィンドウ全体（盤面 + 周囲の UI） |
| **Board** | `Documents/piyo_capture/board/` | `ShogiBoardView` サブツリーのみ、タイトにクロップ |

モードはバッチ開始時にスナップショットされ、実行中はセグメントが無効化される
（＝走行中の切替でモード混在バッチにはならない）。Board モードで
`ShogiBoardView` が見つからなかった場合、ウィンドウ全体へフォールバックせずに
そのレコードをスキップする — モード混在の PNG が `piyo_capture/board/` に
紛れ込まないため。

### 既知の不具合：4841 件目付近でクラッシュ

**CHINLAN sideload IPA** をぴよ将棋 5.7.5 に噛ませて回した場合、
バッチはおよそ **4841 件目**で決定的に落ちる — 4800 件超のペーストを
連続で処理すると `-[UINib instantiateWithOwner:options:]` の内部で
未捕捉 `NSException` が上がり、そのままアプリごと死ぬ。
tweak 側は独自の `NSSetUncaughtExceptionHandler`（Firebase Crashlytics
のハンドラの前段にチェイン、上流の Crashlytics 報告は維持）を仕込んで
例外の name / reason / call stack を `piyoshot.log` に落としているが、
クラッシュ自体はまだ直っていない。

回避策：1 バッチを ~4800 件未満に区切って回すか、実行の合間にアプリを
再起動する — レジューム安全なフィルタが前回の続きから再開してくれるので
撮影済みの PNG がロストすることはない。

## データモデル

**入力** (`position.jsonl`):

```jsonl
{"sfen": "+R2+S2s1l/4skg2/p1ppppnp1/1N4p1p/4Sr3/Pp6P/G2KP1PL1/7P1/LN4GNL b 2BG3Pp 71", "hash": "e3fc4e063461f3cff91f43b61b25b670c74579ae7db87c22acf5c6c41edbcd13"}
{"sfen": "…", "hash": "…"}
```

`hash` は `sha256(sfen)` — そのまま保存 PNG のファイル名になる。

**出力**（キャプチャモード別）:

```
Documents/piyo_capture/
├── screen/
│   ├── 0023de78ce60092ab28c75c203e90427dd68a7ee4cfff720125d73f4676abfb9.png
│   ├── 00ff8c4b…png
│   └── e3fc4e06…png                          ← <hash>.png
└── board/
    ├── 0023de78…png
    └── e3fc4e06…png                          ← <hash>.png（盤面クロップ）
```

途中で中断しても、次回起動時に **現行モードの** 出力ディレクトリ配下に
既に PNG がある行は事前フィルタで落とすので、自動でレジューム扱いになる。
モード毎に独立してレジュームする。

どちらの配布形態にも既定の JSONL が同梱される。Sheet は以下を自動検出：

- **JB rootless deb**: `/var/jb/Library/Application Support/PiyoShot/position.jsonl`
- **CHINLAN sideload IPA**: `Payload/PiyoShogi.app/Frameworks/position.jsonl`（注入した `PiyoShot.dylib` の隣）

## Settings UI

画面右端から左へスワイプ（30 pt の当たり判定・80 pt のトリガー距離）で
inset-grouped 4 セクションの設定シートが開く：

- **JSONL** — Choose JSONL file（ドキュメントピッカーを開く）、読み込み中
  のファイル名、`total / valid / invalid` の行と `captured / remaining`
  の行がスタック表示される。初回表示時に同梱の既定 JSONL が自動読み込みされる。
- **Capture** — Screen / Board の Segmented Control（永続化、実行中は無効化）。
- **Run** — *Run*（`Run (N remaining)` の形。撮る対象が無いときは無効）、
  *Hash check (dedupe)*（破壊操作を示す systemRed）、*Status*（ランナーの
  最新メッセージを反映）。
- **Info** — Version / Commit / 端末上のログパスを別行で表示。`v0.1.0` と
  ビルドハッシュが行内で癒着しない。

バッチ進捗はオーバーレイウィンドウの下中央に描画されるだけで、シート上
には出ない — シートはイテレーション開始前に自らを閉じ、ぴよ将棋に
画面全体を返す。

## 対応環境

| | |
|---|---|
| **対象ぴよ将棋** | `5.7.5`（CFBundleVersion 199）、bundle id `net.studioki.PiyoShogi` |
| **ぴよ将棋の最小 iOS** | 13.0（アプリバンドル `MinimumOSVersion`） |
| **PiyoShot の最小 iOS** | 15.0（`UIWindowScene` を使うため） |
| **テスト済み** | iOS 15.0 – 26, arm64 |
| **配布形態** | Jailbroken rootless `.deb`、CHINLAN Patched IPA（TrollStore / Sideloadly / AltStore） |

配布形態の比較：

| Flavor | 対象 | 仕組み |
|---|---|---|
| **JB rootless deb** | 脱獄済み端末（Dopamine, rootless） | libsubstrate 経由の `MSHookFunction`。Sileo / Zebra から導入。 |
| **CHINLAN sideload IPA** | 非脱獄端末、iOS 15 – 26 | ぴよ将棋のバイナリを静的リライトし、フックサイトを `__DATA` スロット表経由にルーティング。iOS 18 以降の Code Signing Monitor が禁じる `__TEXT` の書き換えをランタイム側で一切要求しない。TrollStore / Sideloadly / AltStore で導入。 |

## ビルド

Theos ツールチェーン（Linux devcontainer サポート済 — `.devcontainer/`
参照）と、CHINLAN IPA ビルドには `pyproject.toml` 固定版の Python 3.12 が必要。

### 脱獄端末（rootless）

`make FINALPACKAGE=1 package install` で release `.deb` をビルドして
SSH 経由で送り込む。devcontainer では既定で `host.docker.internal:2222`
が宛先に設定されている — ホスト側で `iproxy 2222 22` を上げておくこと。

```sh
# release .deb
make FINALPACKAGE=1 package

# usbmuxd / iproxy 経由で JB 実機にビルド + インストール
make FINALPACKAGE=1 package install \
    THEOS_DEVICE_IP=192.168.x.x THEOS_DEVICE_PORT=22
```

デバッグビルドは `FINALPACKAGE=1` を外せばよく、バージョンは
`0.1.0-dbg-N+debug` になる。

### Patched IPA（Sideload / TrollStore）

**復号済みの** ぴよ将棋 IPA が必要（App Store 版は FairPlay 暗号化されて
おり、そのままではパッチできない）。パッチ済み IPA は
[TrollStore](https://github.com/opa334/TrollStore)、
[Sideloadly](https://sideloadly.io/)、
[AltStore](https://altstore.io/) 等で導入。

```sh
# release IPA
make FINALPACKAGE=1 ipa DECRYPTED_IPA=/path/to/PiyoShogi-5.7.5.ipa
# -> packages/ipa/PiyoShot-patched.ipa
```

`make ipa` の裏では `shared/tools/build_patched_ipa.sh`
（[Kanade](https://github.com/IPA-Patch/Kanade) サブモジュール）が呼ばれ、
ぴよ将棋バイナリのフックサイトを `__DATA` スロット表経由にリライトし、
`PiyoShot.dylib` を注入、`position.jsonl` を `Payload/PiyoShogi.app/Frameworks/`
配下に置く。

## アーキテクチャ

- **`Sources/PiyoShot/PiyoOverlay.m`** — 常時表示の透明 `UIWindow`（Alert + 1000 level）。右端の当たり判定でパン認識器を起動し、`PiyoSheetVC` を提示する以外のタッチは全部素通り。
- **`Sources/PiyoShot/PiyoSheetVC.m`** — inset-grouped table。JSONL / Capture / Run / Info の 4 セクション構成。`PiyoBatchRunner` は 1 インスタンスを使い回す。Capture セグメントは実行中無効化されるので、ランナーがスナップショットした出力ディレクトリとモードがズレる余地がない。
- **`Sources/PiyoShot/PiyoBatchRunner.m`** — メインキュー上のイテレータ。pasteboard を書いて `btnKifPasteClicked:` を叩き、`PSParseSFENCallback` で 3 回目の `parseSFEN`（最終の描画準備）が return した瞬間にスナップショットを撮り、現行モードの出力ディレクトリに書き出す。`ShogiBoardView` に対する `setNeedsDisplay + displayIfNeeded + layoutIfNeeded` の 3 点セットが実際に効いている。Board モードでは `ShogiBoardView` が見つからない時にウィンドウ全体へフォールバックせずスキップする — モード混在な PNG が `piyo_capture/board/` に紛れ込まないため。`piyo_capture/<mode>/` を歩くハッシュ検査ループ内の per-file autoreleasepool は落とせない — CHINLAN のサンドボックスは数千ファイル付近で OOM する。
- **`Sources/PiyoShot/Hook/AdHide.m`** — 純粋な ObjC ランタイム swizzle。広告 SDK の `-layoutSubviews` をスキップし、load 系メソッドを NoOp 化する。iPhone 8 で 1 レコード当たりの実時間が ~350 ms → ~143 ms に落ちる（バナーのパルス／フェードが render server を占有しなくなるため）。
- **`Sources/PiyoShot/Hook/ParseSFEN.m`**, **`Sources/PiyoShot/Hook/Validator.m`** — ランナーが引っかけている 2 つの版依存 RVA。`binpatch_sites.h` に定数がある。
- **`Sources/Chinlan/`** サブモジュール ([IPA-Patch/Chinlan](https://github.com/IPA-Patch/Chinlan)) — 共有のケーブフックランタイム + ログ機構。
- **`shared/`** サブモジュール ([IPA-Patch/Kanade](https://github.com/IPA-Patch/Kanade)) — 静的パッチ用の Python ツール。`make ipa` の裏で `shared/tools/build_patched_ipa.sh` が呼ばれる。

## 端末内で完結する話

PiyoShot が触るのは **プロセスメモリ** と
**ぴよ将棋自身のサンドボックス内のファイル** だけ。以下は一切やらない：

- ぴよ将棋のサーバに向けたリクエストを組み立てて送る
- キャプチャしたリクエストを再送する
- ネットワークの中継 / MITM
- アカウントに紐づくデータ・サーバ側状態の書き換え

全てのフックを外して起動し直せば、素のぴよ将棋に戻る。
