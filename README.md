# uparupa

macOS 専用のターミナルエミュレータ。Swift（AppKit、Metal）と Zig で書き、端末エミュレーションは [libghostty-vt](https://lib.ghostty.org/vt/) に任せている。名前はウーパールーパーから。

対応しているのは macOS 13 以上の Apple Silicon。

## インストール

```sh
curl -fsSL https://raw.githubusercontent.com/Matuyuhi/uparupa/main/install.sh | sh
```

`~/Applications/uparupa.app` と `~/.local/bin/uparupa` が置かれる。管理者権限は使わない。取得したファイルは SHA-256 を確かめてから展開する。

```sh
uparupa            # 開く
uparupa update     # 最新のリリースを入れ直す
uparupa --version
```

起動時に、新しいリリースが出ていないかを 1 日 1 回だけ GitHub に問い合わせる。知らせるだけで、自動では更新しない。止めるには環境変数 `UPARUPA_NO_UPDATE_CHECK=1` を設定する。

## 開発

必要なもの: Xcode 27（Metal Toolchain を含む）、Zig 0.17.x、minisign。

```sh
sh scripts/fetch-ghostty-vt.sh   # libghostty-vt を取得する（署名と SHA-256 を確かめる）
sh scripts/build-app.sh          # build/uparupa.app を作る
sh scripts/test.sh               # テスト一式
```

構成と決まりごとは `CLAUDE.md`、経緯と確認済みの事実は `docs/handoff.md` にある。

## ライセンス

MIT（`LICENSE`）。同梱している libghostty-vt などのライセンスは `THIRD_PARTY_LICENSES.md` にある。
