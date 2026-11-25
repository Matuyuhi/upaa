# uparupa

macOS 専用の自作ターミナルエミュレータ。Swift（AppKit）と Zig で書き、端末エミュレーションの中身は libghostty-vt（安定版の C ABI）に任せる。目標は普段使いできること。

経緯、確認済みの事実、未確認事項、マイルストーンは `docs/handoff.md` にある。着手前に読むこと。

## 決まっていること

- 対象は macOS 13 以上の Apple Silicon（arm64）のみ。クロスプラットフォーム対応はしない。
- 言語は Swift と Zig の混成。UI・IME・Metal の呼び出しは Swift、それ以外の中核（PTY、libghostty-vt の呼び出し、描画用データの組み立て、グリフのキャッシュ）は Zig。Zig は 0.17.x。
- ビルドは SwiftPM と `scripts/build-app.sh`（`zig build` → `swift build` → `build/uparupa.app`）。
- libghostty-vt はビルド済みの XCFramework を `scripts/fetch-ghostty-vt.sh` で取得する。リポジトリには含めない。
- libghostty-vt 1.0.x を使う。描画とフォントまで含むフル libghostty（GhosttyKit など）は API が未安定なので使わない。
- 描画は Metal、グリフの生成は CoreText。
- 日本語の表示と IME は後回しにしない。

## 構成

- `core/src/` — Zig の中核。C に公開する関数（`export fn`）は `root.zig` だけに置き、中身は役割ごとのフォルダに書く。
  - `c/` translate-c で取り込むヘッダ、`term/` 端末セッション（PTY、読み取りスレッド、libghostty-vt）、`font/` フォントとグリフのアトラス、`render/` Metal に渡すセルのデータの組み立て、`selftest.zig` リンクの確認用。
- `Sources/CUparupaCore/` — Zig の関数の C ヘッダ。`root.zig` と対で直し、形を変えたら ABI の番号を両方で上げる。
- `Sources/UparupaKit/` — Swift の中身（`App/`、`Terminal/`、`Render/`、`SelfTest/`）。`Sources/uparupa/` は起動するだけ。
- `Shaders/` — Metal のシェーダ。`scripts/build-app.sh` がコンパイルして `.app` に入れる。セルのデータの並びは `core/src/render/Cell.zig`、C ヘッダの `UparupaCell`、シェーダの `Cell` の 3 か所で揃える。
- 描画の確認は `build/uparupa.app/Contents/MacOS/uparupa --snapshot <png> [--input <文字列>]` で 1 フレームを PNG に書き出して見る。キー入力の確認は `--type <文字列>`、計測は `--bench-cat <ファイル>` と `--bench-keys`（どれもウィンドウが開く）。
- テストは `sh scripts/test.sh`（Zig のテスト、`--check`、`tests/fixtures/*.vt` の画面と `tests/snapshots/` の基準の画像の比較、速さの下限・上限）。描画を意図して変えたときは `UPDATE_SNAPSHOTS=1 sh scripts/test.sh` で基準を置き換え、画像を見てから commit する。GitHub Actions（`.github/workflows/test.yml`）も同じスクリプトを呼ぶ。
- `swift build` と PTY を使うテスト（`zig build test`）は Claude Code のサンドボックスの中では動かない。

## バージョンとリリース

- バージョンは `build.zig.zon` の `.version` だけに書く。Zig のコード、Swift（`uparupa --version`、更新確認）、`.app` の `Info.plist` はここから取る。ほかの場所に番号を書かない。
- リリースは、`build.zig.zon` の番号を上げて commit し、同じ番号のタグ（`v0.1.0` の形）を push する。`.github/workflows/release.yml` がテストを通してから zip と `SHA256SUMS` を GitHub の Releases に置く。タグと番号が違えば失敗する。
- インストールは `install.sh`（`curl ... | sh`）。`~/Applications/uparupa.app` と `~/.local/bin/uparupa` を置く。`uparupa` コマンドの中身は `scripts/uparupa-launcher.sh`。
- 起動時の更新確認は `Sources/UparupaKit/App/UpdateCheck.swift`。1 日 1 回だけ GitHub に問い合わせ、知らせるだけで更新はしない。

## 守ること

- libghostty-vt の関数名や使い方は、タグ `vt-1.0.2` のヘッダ（`include/ghostty/vt/`）と `example/c-vt-*` を正とする。Ghostling は 1.0 より前のコミットに固定されていて、1.0.2 に存在しない関数を呼んでいる。
- 報告では、確認した事実と推測を分けて書く。動かしていないものを「動く」と書かない。
- 外部からのダウンロード、公開、削除や上書きを伴う操作は、対象と影響を示してユーザーの確認を取ってから行う。
- 秘密鍵やトークンなどの認証情報をユーザーに入力させない。
