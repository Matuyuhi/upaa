# wren

macOS 専用の自作ターミナルエミュレータ。Swift（AppKit）と Zig で書き、端末エミュレーションの中身は libghostty-vt（安定版の C ABI）に任せる。目標は普段使いできること。

経緯、確認済みの事実、未確認事項、マイルストーンは `docs/handoff.md` にある。着手前に読むこと。

## 決まっていること

- 対象は macOS 13 以上の Apple Silicon（arm64）のみ。クロスプラットフォーム対応はしない。
- 言語は Swift と Zig の混成。UI・IME・Metal の呼び出しは Swift、それ以外の中核（PTY、libghostty-vt の呼び出し、描画用データの組み立て、グリフのキャッシュ）は Zig。Zig は 0.17.x。
- ビルドは SwiftPM と `scripts/build-app.sh`（`zig build` → `swift build` → `build/wren.app`）。
- libghostty-vt はビルド済みの XCFramework を `scripts/fetch-ghostty-vt.sh` で取得する。リポジトリには含めない。
- libghostty-vt 1.0.x を使う。描画とフォントまで含むフル libghostty（GhosttyKit など）は API が未安定なので使わない。
- 描画は Metal、グリフの生成は CoreText。
- 日本語の表示と IME は後回しにしない。

## 守ること

- libghostty-vt の関数名や使い方は、タグ `vt-1.0.2` のヘッダ（`include/ghostty/vt/`）と `example/c-vt-*` を正とする。Ghostling は 1.0 より前のコミットに固定されていて、1.0.2 に存在しない関数を呼んでいる。
- 報告では、確認した事実と推測を分けて書く。動かしていないものを「動く」と書かない。
- 外部からのダウンロード、公開、削除や上書きを伴う操作は、対象と影響を示してユーザーの確認を取ってから行う。
- 秘密鍵やトークンなどの認証情報をユーザーに入力させない。
