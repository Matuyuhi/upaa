# wren 引き継ぎ資料

作成日: 2026-11-25（同日、言語構成の決定を反映して改訂）
対象: この資料をもとに実装を進める Claude Code

wren は macOS 専用の自作ターミナルエミュレータ。名前はミソサザイ（小さいのによくさえずる鳥）から。
この資料は、実装前の会話で決まったこと、一次情報で確認できたこと、確認できていないことを分けて書いている。
コードはまだ 1 行もない。

## 1. 決定事項

ユーザーが決めたこと。変える場合はユーザーに確認する。

| 項目 | 決定 |
|---|---|
| 名前 | wren |
| 目的 | 普段使いできるターミナルにする（学習用の最小実装で終わらせない） |
| 対象 OS | macOS のみ |
| 言語の構成 | Swift と Zig の混成。UI・IME・Metal の呼び出しは Swift、それ以外の中核は Zig |
| 描画 | Metal を使う。グリフの生成は CoreText |
| 端末エミュレーションの中身 | libghostty-vt（安定版の C ABI）を使う |
| Zig のバージョン | 0.17.x |
| 実装の担当 | 本格的な実装は Claude Code で行う |
| 対応する macOS | 13 以上（2026-11-25 決定） |
| アーキテクチャ | Apple Silicon（arm64）のみ（2026-11-25 決定） |
| プロジェクトの形 | SwiftPM と、`.app` を組み立てるシェルスクリプト 1 本（2026-11-25 決定） |
| XCFramework の置き方 | リポジトリに含めず、取得スクリプトで取って署名と SHA-256 を確かめる（2026-11-25 決定） |

Zig を選んだ理由は「Zig で書きたい」というユーザーの希望。合理性だけなら C のほうがビルドの手間が少ないことは、ユーザーに伝えたうえでの決定である。

条件が 1 つ付いている。この混成は「性能や合理性が著しく落ちない」ことが前提で、無理だと分かった場合は無理だとはっきり伝える約束になっている。M0（5 章）がその見極めの場になる。

検討して採らなかった案。

- クロスプラットフォーム GUI: 当初の希望だったが、macOS 専用でよいとなり取り下げ。
- Electrobun + webview: 描画・フォント・IME を WebKit に任せられるが、描画性能と入力遅延の上限が低くなる見込みのため見送り。
- フル libghostty（描画とフォントまで含むもの。GhosttyKit など）: API が未安定で、自作の意味も薄くなるため見送り。
- 全部 Swift: いちばん単純だが、Zig で書きたいという希望に合わない。
- 中核を C: ビルドの手間は最小。M0 が通らなかった場合の切り替え先として残す。
- UI や Metal の呼び出しまで Zig: Ghostty はやっているが、専用のライブラリと包む層を自前で持っている。個人プロジェクトでは手間に見合わないと判断。

## 2. 確認済みの事実

2026-11-25 時点。出典を併記する。リポジトリの記述は `ghostty-org/ghostty` のタグ `vt-1.0.2` を読んで確認した。

### libghostty-vt のバージョンと安定性

- libghostty-vt 1.0.0 は 2026-11-06 公開。この版から C ABI が安定。1.0.1 は 11-11、1.0.2 は 11-24 公開で、どちらも性能改善が中心。（リリースノート）
- libghostty-vt は Ghostty アプリとは別のバージョン番号を持ち、タグは `vt-X.Y.Z`。（`PACKAGING-LIBGHOSTTY.md`）
- セマンティックバージョニングで ABI 互換を保証し、CI で検査している。（作者の 1.0 記事）
- 描画・ウィンドウ・PTY は含まれない。利用側が用意する。（Ghostling の README）

### libghostty-vt の入手方法

- ビルド済みの XCFramework が配布されている。場所は次の形式。（`PACKAGING-LIBGHOSTTY.md`）

  ```
  https://release.files.ghostty.org/libghostty-vt/VERSION/ghostty-vt-VERSION.xcframework.zip
  ```

  各ファイルに `.minisig` の署名があり、同じ場所に `SHA256SUMS` と `SHA256SUMS.minisig` がある。minisign の公開鍵は次のとおり。

  ```
  RWQlAjJC23149WL2sEpT/l0QKy7hMIFhYdQOFy0Z7z7PbneUgvlsnYcV
  ```

- 公式に Swift 用の例 `example/swift-vt-xcframework` がある。`Package.swift` は swift-tools-version 5.9、`platforms: [.macOS(.v13)]`、XCFramework を `binaryTarget`（名前は `GhosttyVt`）として参照し、ソースでは `import GhosttyVt` と書いている。
- ソースからビルドする場合、1.0.x は Zig 0.17.x が必要（0.16 と 0.18 は不可）。`build.zig.zon` の `minimum_zig_version` は `0.17.0`。
- Git チェックアウトからビルドする場合は `-Demit-lib-vt` が必要。付けないと Ghostty アプリ本体がビルドされる。XCFramework も作るなら `-Demit-xcframework=true` を足す。

### Zig 0.17.0

出典は公式のリリースノート。

- 最新の安定版は 0.17.0。リリースノートに日付の記載はなく、別の記事では 2026 年 10 月の公開とされている。0.17.1 は検索した範囲では見つからなかったが、M0 の時点（2026-11-25）で Homebrew に 0.17.1 があり、手元はそれを使っている。
- `@cImport` は削除された。C のヘッダは、translate-c パッケージを `build.zig` の依存に加えて取り込む。リリースノートの移行手順は `zig fetch --save git+https://codeberg.org/ziglang/translate-c#zig-0.17.x` から始まる。
- ただし M0 で試したところ、0.17.1 の標準の `std.Build.addTranslateC` は残っていて、外部パッケージを取得せずに Apple のヘッダ（CoreFoundation、CoreGraphics、CoreText）と `<ghostty/vt.h>` を取り込めた。
- ビルドシステムが作り直され、`build.zig` の API が変わった（`b.build_root` → `b.root` など）。0.16 向けの記事やサンプルはそのままでは動かない。
- `@bitCast` の意味が変わった。配列やベクタでは、コンパイルエラーにならずに結果が変わる場合があるとリリースノートが警告している。
- 言語サーバー（ZLS）は 0.17.0 では完全には動かない。一部の機能は復旧済みで、対応は進行中。
- `aarch64-macos` は Tier 2。`x86_64-macos` は廃止予定の扱い。
- 1.0 の時期は示されていない。0.17.0 は 5 か月分の開発をまとめた版。

### M0 で確認したこと（2026-11-25）

- Swift と Zig のつなぎ方: Zig が静的ライブラリ `zig-out/lib/libwrencore.a` を作り（compiler_rt を同梱）、SwiftPM の C ターゲット `CWrenCore`（手書きの C ヘッダ `include/wren_core.h` と空の `shim.c`）の `linkedLibrary("wrencore")` でリンクする。検索パスは `Package.swift` から `-L zig-out/lib` で渡す。Zig のコードだけを変えたときも、C ヘッダだけを変えたときも、`scripts/build-app.sh` で反映されることを確認した。最初は `systemLibrary` ターゲットにしたが、ヘッダを変えても debug ビルドで Swift が再コンパイルされなかったのでやめた。
- libghostty-vt: Zig は `<ghostty/vt.h>` を translate-c で取り込んで C API を呼ぶだけで、ライブラリ本体は Swift 側の最終リンクで `binaryTarget`（XCFramework）から入れる。Zig のテストの実行ファイルは、XCFramework の中の `libghostty-vt.a`（arm64 と x86_64 のファット）を `addObjectFile` で直接指してリンクできた。wren の静的ライブラリと libghostty-vt の両方に compiler_rt が入っているが、リンクでシンボルの重複エラーは出ていない。
- Zig から libghostty-vt で 80x24 の端末を作って VT のバイト列を書き、formatter でプレーンテキストに戻せた（`Hello, \x1b[1;32mworld\x1b[0m!\r\nあいう` → `Hello, world!\nあいう`）。
- ターゲットを `aarch64-macos.13.0` と明示すると Zig は SDK を自動で探さず、フレームワークが見つからない。`build.zig` で `xcrun --sdk macosx --show-sdk-path` の結果を検索パスに渡せば足りた。Ghostty の `apple_sdk` に当たる仕組みは今のところ要らない。
- Zig から CoreText を呼び、Menlo の 'A'（glyph 36）と、フォールバックで HiraginoSans-W3 の「あ」（glyph 843）を取れた。macOS 27.2.1 で、`.app` 内の実行ファイルを直接起動して確認した。
- `swift build` は内部で `sandbox-exec` を使うため、Claude Code のサンドボックスの中では動かない。サンドボックスの外で実行している。
- 未解明: 最終的な実行ファイルの `LC_BUILD_VERSION` が `minos 13.0 / sdk 13.0` になる。Zig で直接リンクしたものは `sdk 27.0` だった。AppKit はリンク時の SDK のバージョンで振る舞いを変えるので、M1 の前に調べる。

### M1 の計測（2026-11-26）

Apple M4 Max、内蔵ディスプレイ（3024 x 1964）、macOS 27.2.1。80 桁 x 24 行のウィンドウで、実際に描画しながら測った。測り方は `wren --bench-cat <ファイル>` と `wren --bench-keys`（`Sources/WrenKit/App/Automation.swift`）。

| 項目 | 結果 |
|---|---|
| 50 MB のテキスト（1 行 100 文字の base64）を `cat` | 0.45〜0.67 秒（75〜110 MB/秒）。3 回測って 1 回目が遅い |
| その間に描いたフレーム | 56〜80 枚 |
| 1 フレームの組み立て（CPU 側。Zig がセルを書き、Swift が描画命令を出すまで） | release で平均 0.13〜0.16 ミリ秒、debug で 0.31〜0.33 ミリ秒 |
| キーを受け取ってから、その文字を描いたフレームが画面に出るまで | 中央値 23〜28 ミリ秒、最大 31〜36 ミリ秒（60 回 x 2） |

- `cat` の時間は release と debug でほぼ同じだった。wren のコードではなく、libghostty-vt の解釈か PTY の受け渡しで決まっていると見ている（切り分けはしていない）。
- 毎フレーム全セルを書き直す作りのままで、1 フレームの組み立ては 1 ミリ秒に届かない。変更行だけを書く差分描画は、今は要らない。
- キーから表示までの時間には、シェルが文字をエコーするまでの時間と、画面の更新を待つ時間が入っている。キーボードそのものの遅れと、ディスプレイの応答は入っていない。値が 8 ミリ秒前後の刻みで並ぶので、画面の更新 3 回分ほど待っていると見ている（推測）。短くするなら、`MTKView` の「次の更新で描く」をやめてすぐ描く形にするのが候補。
- Terminal.app など、ほかのターミナルとの比較はしていない。

### Ghostty 本体の作り

wren と同じ「Swift + Zig」の混成で作られている。参考にできる。

- macOS アプリ側は Swift（`macos/` 配下に約 200 ファイル）、中核は Zig（`src/` 配下に約 620 ファイル）。
- PTY（`src/pty.zig`、`src/termio/`）、CoreText を使うフォント処理（`src/font/face/coretext.zig`、`src/font/shaper/coretext.zig`）は Zig 側にある。
- Metal の描画も Zig 側にあり（`src/renderer/Metal.zig`、`src/renderer/metal/`）、Objective-C ランタイム経由で呼んでいる。wren はここを Swift で書く点が違う。
- Apple のヘッダを Zig に取り込む仕組みは `pkg/macos/build.zig` にある。translate-c と、Apple SDK のパスを解決する `apple_sdk` を使い、`linkFramework` でフレームワークをリンクしている。

### C API の形

ヘッダは `<ghostty/vt.h>` だけを include すればよい。以下は `include/ghostty/vt/` と `example/c-vt-*` で確認した関数名。

- 端末: `ghostty_terminal_new(allocator, &terminal, cols, rows)`、`ghostty_terminal_vt_write`、`ghostty_terminal_resize`、`ghostty_terminal_scroll_viewport`、`ghostty_terminal_get` / `ghostty_terminal_set`、`ghostty_terminal_free`。
- 端末からの通知: `ghostty_terminal_set` にコールバックを渡す。`GHOSTTY_TERMINAL_OPT_WRITE_PTY`（端末が PTY に書き戻したいバイト列）、`_USERDATA`、`_BELL`、`_TITLE_CHANGED`、`_PWD_CHANGED`、`_CLIPBOARD_READ`、`_CLIPBOARD_WRITE` など。例は `example/c-vt-effects`。
- 描画用の状態: `ghostty_render_state_new` → `ghostty_render_state_update(state, terminal)` → 行イテレータ（`ghostty_render_state_row_iterator_next_dirty` で変更行だけ回せる）→ セルの取得 → `ghostty_render_state_clean`。例は `example/c-vt-render`。
- 描画用の状態の更新は 2 段階にも分けられる。`ghostty_render_state_begin_update` だけが端末へのアクセスを必要とし、`ghostty_render_state_end_update` は端末が書き換えられている最中でも呼べる。IO スレッドと共有するロックを短く持つための作り。（`render.h` のコメント）
- キー入力: `ghostty_key_event_*` でイベントを組み立て、`ghostty_key_encoder_encode` でバイト列にする。`ghostty_key_encoder_set_from_terminal` で端末のモードを反映する。IME 変換中かどうかを渡す `ghostty_key_event_set_composing` がある。
- マウス入力: `ghostty_mouse_event_*` と `ghostty_mouse_encoder_*`。
- そのほか: 貼り付け（`ghostty_paste_encode`、`ghostty_paste_is_safe`）、フォーカス通知（`ghostty_focus_encode`）、選択（`ghostty_selection_gesture_*`）、検索（`ghostty_search_*`）、整形出力（`ghostty_formatter_*`）、文字幅（`ghostty_unicode_grapheme_width`）、Kitty 画像（`kitty_graphics.h`）。

### Ghostling を参考にするときの注意

- Ghostling は公式の最小実装（C の単一ファイル、Raylib 使用）で、README が「普段使い向けではない」と明記している。文字のシェーピングはしていない。
- Ghostling が固定している Ghostty のコミットは `f64f4aca`（Ghostling 側の最終コミットは 2026-08-09）で、1.0 より前のもの。
- Ghostling の `main.c` が呼んでいる関数のうち、次の 5 つは `vt-1.0.2` のヘッダに存在しない。

  ```
  ghostty_key_encoder_setopt_from_terminal
  ghostty_mouse_encoder_setopt
  ghostty_mouse_encoder_setopt_from_terminal
  ghostty_render_state_colors_get
  ghostty_mods
  ```

  全体の組み立て方（PTY の読み書き、描画ループ、入力の流れ）は参考になるが、関数名は `vt-1.0.2` のヘッダと `example/c-vt-*` を正とすること。
- Ghostling の README は Zig 0.16.x を要求している。libghostty-vt 1.0.x の要求（0.17.x）とは違う。

## 3. 確認できていないこと

着手前か、該当する作業の中で確かめる。上の 4 つは M0 で確かめる。

- （M0 で確認済み。2 章「M0 で確認したこと」）Swift のアプリと Zig の静的ライブラリをつなぐ具体的な手順。SwiftPM も Xcode も Zig を直接ビルドできないので、`zig build` で静的ライブラリと C ヘッダを作ってリンクする形になるはずだが、試していない。
- （M0 で確認済み。`apple_sdk` 相当は不要だった）自分のプロジェクトで、translate-c を使って Apple のヘッダ（CoreText、CoreGraphics）と `<ghostty/vt.h>` を Zig に取り込めるか。Ghostty は `apple_sdk` という自前の仕組みを使っており、同じことが要るかは未確認。
- （M0 で確認済み）静的ライブラリ `libghostty-vt.a`。macOS 向けは arm64 と x86_64 のファット（ほかに iOS 向け 2 つ）。各オブジェクトの `minos` は 13.0。モジュール名は `GhosttyVt`（`module.modulemap` の umbrella header は `ghostty/vt.h`）。1.0.2 の zip の SHA-256 は `15477209ce86ad1c944f217e925c84acf796ecc51aba7a935aaa1a7769890bd6` で、minisign の署名も確認した。元の記述: XCFramework の中身。この資料を作った環境からは `release.files.ghostty.org` に接続できず、ダウンロードして確かめられなかった。含まれるアーキテクチャ（arm64 / x86_64）、静的か動的か、モジュール名が本当に `GhosttyVt` か、SHA-256 の値は未確認。
- （M0 で確認済み。中の `.a` を直接指せばリンクできる）XCFramework 内のライブラリを Zig のビルドからリンクできるか。XCFramework は Xcode と SwiftPM 向けの形式なので、Zig 側は中のライブラリファイルを直接指す必要があるかもしれない。
- Zig 0.17.0 が対応する macOS の最低バージョン。リリースノートに「Darwin 15.0+」とあるが、macOS のどの版に当たるかを確かめていない。
- libghostty-vt の Zig API が C ABI と同じ安定保証の対象かどうか。wren は C API を使うので影響は小さい。
- スレッド安全性の正確な範囲。第三者の Rust バインディングの文書には「特記がない限りスレッドセーフではない」とある。公式ヘッダの記述を読んで確かめること。
- `wren` という名前の重複。同名のスクリプト言語 Wren があり、CLI は Homebrew で `wren-cli` として配布されている。ターミナルエミュレータでは 1 回の検索で見つからなかったが、網羅的には調べていない。
- 性能。何も測っていない。この資料の性能に関する記述はすべて見立てである。

## 4. 構成の案

層の分け方（どこを Swift、どこを Zig で書くか）はユーザーと合意済み。細部は見立てなので、実装しながら見直してよい。

### 層の分け方

| 層 | 言語 | 理由 |
|---|---|---|
| ウィンドウ、メニュー、タブ、設定画面 | Swift | AppKit をそのまま書ける |
| 日本語 IME（`NSTextInputClient`） | Swift | Objective-C のプロトコル実装が必要 |
| Metal の初期化と描画命令 | Swift | 1 フレームに数回の呼び出しで、速度に効かない |
| シェーダ | Metal Shading Language | 選択の余地がない |
| PTY の生成と読み書きスレッド | Zig | POSIX の API で、UI に依存しない |
| libghostty-vt の保持、ロック、入力のエンコード | Zig | C API を呼ぶだけ |
| 描画用データの組み立て | Zig | 全セルをなめる、いちばん重いループ |
| グリフのキャッシュとアトラス | Zig | 上のループから毎セル参照される。CoreText は C の API なので Zig から呼べる |

```
[Swift] キー入力 / IME ──> [Zig] キーエンコーダ ──> PTY（子プロセス = シェル）
                                                      │ 出力
                                                      v
                                        [Zig] ghostty_terminal_vt_write
                                                      │
                                                      v
                        [Zig] 描画用の状態をなめて、頂点データを Metal のバッファに書く
                                                      │
                                                      v
                                        [Swift] Metal の描画命令を発行
```

### 境界の決まり

- Zig 側は C の関数として公開し（`export fn` と C ヘッダ）、Swift からは C の関数として呼ぶ。
- 言語をまたぐのは、フレーム単位か、PTY から読んだかたまり単位にする。セル 1 個ごとに Swift へコールバックする設計にはしない。ここを守らないと、混成にした意味がなくなる。
- Swift 側が Metal のバッファのポインタを渡し、Zig 側がそこへ直接書き込む。コピーを挟まない。
- Zig 側から Swift 側への通知（タイトル変更、ベル、再描画の要求など）は、頻度の低いものに限ってコールバックで渡す。

### libghostty-vt の使い方

- ビルド済みの XCFramework をリンクし、Zig からは C API を呼ぶ。
- こうする理由は、Zig の版と libghostty-vt の版を切り離すため。libghostty-vt をソースからビルドすると Zig の版が libghostty-vt 側の指定に縛られ、将来 Zig を上げたいときに上げられなくなる。
- libghostty-vt の Zig API は使わない。同じ版の Zig でソースからビルドする必要があり、安定保証の対象かも未確認のため。

### そのほかの見立て

- 端末 1 つにつき、PTY、`GhosttyTerminal`、描画用の状態を Zig 側で 1 組持つ。
- PTY の読み取りは専用スレッドで行い、端末への書き込みと描画用の状態の更新は 1 つのロックで守る。`ghostty_render_state_begin_update` / `end_update` の 2 段階を使えば、ロックを持つ時間を短くできる。
- 日本語 IME は早い段階で通す。後回しにすると入力まわりの作り直しが大きくなる。
- `.app` として起動できる形が早めに必要になる見込み。SwiftPM の実行ファイルのままだと、メニューや IME の挙動が通常のアプリと違う可能性がある（未検証）。Xcode プロジェクトにするか、SwiftPM とバンドルを作るスクリプトにするかは未決定。

### Zig を使ううえでの負担

ユーザーには伝えてある。実装中に重くなりすぎたら、隠さず報告すること。

- ビルドの仕組み（translate-c、Apple SDK のパス、Swift とのリンク）を自分で組む必要がある。
- Zig の版が上がるたびに修正が要る可能性が高い。次の版の時期は公表されていない。
- ZLS が 0.17.0 で完全には動かないので、エディタの補完や定義ジャンプが効きにくい。

## 5. マイルストーン

各段階に「できたと言える条件」を付けた。M2 までは 1 つずつ進めるのがよい。

| 段階 | 内容 | できたと言える条件 |
|---|---|---|
| M0 | 混成の土台を通す | (1) Swift から Zig の関数を呼べる。(2) Zig から libghostty-vt を呼び、端末を作って文字列を書き、プレーンテキストで取り出せる。(3) Zig から CoreText を呼び、1 文字のグリフを取得できる。3 つとも `.app` かそれに準じる形で動く |
| M1 | ウィンドウ + PTY + Metal 描画 | ウィンドウ内でシェルが動き、`ls` と `vim` が表示でき、ウィンドウのリサイズに追従する |
| M2 | 日本語の表示と入力 | 全角文字が 2 セル幅で崩れず、IME の変換中の文字列が表示され、確定した文字がシェルに届く |
| M3 | 普段使いの最低限 | 文字列の選択とコピー、貼り付け、スクロールバック、マウス対応アプリの操作ができる |
| M4 | 見た目と設定 | フォント・配色・ウィンドウサイズを設定ファイルで変えられる |
| M5 | 拡張 | タブか分割、検索 UI |

M0 について。

- M0 は、Zig を選んだことの見極めを兼ねる。ここが通れば残りは普通の実装になる。
- M0 のどれかが通らない、または通すための仕組みが大きくなりすぎる場合は、そこで止めてユーザーに報告する。切り替え先の候補は「中核を C で書く」で、層の分け方はそのまま使える。
- XCFramework の取得は外部からのダウンロードなので、対象の URL と検証方法を示してユーザーの確認を取ってから行う。

M1 について。

- 大量出力（例: 大きなファイルの `cat`）にかかる時間と、キー入力から表示までの遅れを測っておく。以降の判断を数字でできるようになる。
- Metal の立ち上げに手間取る場合は、いったん単純な描画でシェルの動作だけ先に確認してもよい。ただし Zig 側が作るデータの形は Metal 向けのままにしておく。

## 6. ユーザーに確認が必要なこと

「公開するか」以外は 2026-11-25 に決まった（1 章の表）。

- 対応する macOS の最低バージョン（公式の Swift 例は macOS 13 以上）。
- Apple Silicon だけを対象にしてよいか。Zig 0.17.0 で `x86_64-macos` は廃止予定の扱いになっている。
- Xcode プロジェクトにするか、SwiftPM 中心にするか。
- 公開するか、個人用にとどめるか（名前の重複やライセンス表記の扱いが変わる）。
- XCFramework をリポジトリに含めるか、取得スクリプトにするか。

## 7. 参照先

- libghostty-vt の文書: https://lib.ghostty.org/vt/
- libghostty-vt のリリースノート: https://lib.ghostty.org/vt/release-notes.html
- 作者の 1.0 記事: https://mitchellh.com/writing/libghostty-1-0
- ソースと例: https://github.com/ghostty-org/ghostty （タグ `vt-1.0.2`、`include/ghostty/vt/`、`example/`、`pkg/macos/`、`PACKAGING-LIBGHOSTTY.md`）
- Ghostling: https://github.com/ghostty-org/ghostling
- Zig 0.17.0 のリリースノート: https://ziglang.org/download/0.17.0/release-notes.html
- 関連プロジェクトの一覧: https://github.com/Uzaaft/awesome-libghostty
