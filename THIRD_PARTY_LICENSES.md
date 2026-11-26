# 同梱している第三者のソフトウェア

upaa は libghostty-vt 1.0.2 を静的にリンクして配布している。libghostty-vt 自身と、その中にコンパイルされているライブラリは次のとおり。
一覧は、ghostty のタグ `vt-1.0.2` にある `deps/libghostty-vt-third-party.json` の「linked」の項目から取った。

| 名前 | バージョン | ライセンス | 入手元 |
|---|---|---|---|
| libghostty-vt | 1.0.2 | MIT | https://github.com/ghostty-org/ghostty |
| highway | 1.2.0 | Apache-2.0 OR BSD-3-Clause | https://deps.files.ghostty.org/highway-66486a10623fa0d72fe91260f96c892e41aceb06.tar.gz |
| simdutf | 9.0.0 | Apache-2.0 OR MIT | https://github.com/simdutf/simdutf |
| translate_c | 2.0.0 | MIT | https://deps.files.ghostty.org/translate_c-02ff0c523fb92a38939b04d0145c4a9602a74d56.tar.gz |
| uucode | 0.2.0 | MIT AND Unicode-3.0 | https://deps.files.ghostty.org/uucode-1fb73433bba5d93366c57f23ff2e9d7939746500.tar.gz |
| wuffs | 0.4.0-alpha.10 | Apache-2.0 OR MIT | https://deps.files.ghostty.org/wuffs-7411f488fe2e2c205c3d3b3d28638b7356522930.tar.gz |

各ライブラリのライセンスの全文と著作権表示は、それぞれの入手元のソースに含まれている。

## libghostty-vt（MIT）

```
MIT License

Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
