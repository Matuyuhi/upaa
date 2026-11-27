#!/usr/bin/env python3
"""upaa のマスコット（ウーパールーパー）の点描を、口や目の状態ごとに書き出す。

使い方: python3 upaa_art.py <出力先フォルダ> [倍率=2.0]
必要なもの: Python 3、Pillow（プレビュー画像を作るときだけ）

出力:
  frames.json        点ごとの色データ（upaa が自分で点を描くとき用）
  <フレーム名>.ans   点字の文字で描いた色つきテキスト（ほかの端末で cat するとき用）
  preview.png        全フレームを並べた確認用画像
  preview.gif        口の開閉を動かした確認用アニメーション
"""
import json, math, os, sys
from collections import Counter

DESIGN = 40   # 絵の設計上の一辺（アプリアイコンと同じ座標系）
T = -12       # 頭の傾き（度）
LIGHT = (-0.35, -0.45, 0.85)

# フレームごとの姿勢。
#   mouth: 口の開き（0 = 閉じる、1 = アイコンと同じ、1.3 = 大きく開く）
#   eyes:  目を開けているか
#   lift:  頭（えら・顔ごと）を何点ぶん上げるか。点の単位でずらすので、ちらつかない
#   gill:  えらの広がり（0 = ふだん、1 = いっぱいに広げる、負 = 少し閉じる）
#   body:  体の伸び縮み（正 = 縦に伸びる、負 = 縮む）
FRAMES = [
    # name            mouth eyes   lift gill  body
    ("mouth-closed",        0.0, True,   0,   0.0,  0.0),
    ("mouth-half",    0.5, True,   1,   0.4,  0.0),
    ("mouth-open",    1.0, True,   2,   0.8,  0.02),
    ("mouth-wide",    1.3, True,   3,   1.0,  0.03),
    ("settle",        0.0, True,  -1,  -0.2, -0.015),   # 閉じた直後に少し沈む
    ("blink",         0.0, False,  0,   0.0,  0.0),
    ("idle-gill-a",   0.0, True,   0,   0.25, 0.0),    # 待機中にえらをゆらす
    ("idle-gill-b",   0.0, True,   0,  -0.15, 0.0),
]

BASE = {'hi': (246, 244, 250), 'mid': (196, 190, 222), 'lo': (118, 112, 158)}
ORDER = ['hi', 'mid', 'lo']
TINTS = [(0, 0, 0), (0, 0, 0), (0, 0, 0), (-14, -4, 10), (-20, 2, 6), (-6, -10, 12)]
BITS = [(0, 0, 0x01), (0, 1, 0x02), (0, 2, 0x04), (1, 0, 0x08),
        (1, 1, 0x10), (1, 2, 0x20), (0, 3, 0x40), (1, 3, 0x80)]


def draw(S, mouth, eyes_open, lift=0, gill=0.0, body=0.0):
    """1 フレーム分の点（tone と、その点がどの部位か）を返す。"""
    GW = int(DESIGN * S) // 2 * 2
    GH = (int(DESIGN * S) + 3) // 4 * 4
    tone = [[None] * GW for _ in range(GH)]
    own = [[None] * GW for _ in range(GH)]
    n = math.sqrt(sum(v * v for v in LIGHT)); L = tuple(v / n for v in LIGHT)
    cur = ['']

    def each(cx, cy, rx, ry, deg):
        cx, cy, rx, ry = cx * S, cy * S, rx * S, ry * S
        a = math.radians(deg); c, s = math.cos(a), math.sin(a)
        for y in range(GH):
            for x in range(GW):
                dx, dy = x + 0.5 - cx, y + 0.5 - cy
                yield x, y, dx * c + dy * s, -dx * s + dy * c, rx, ry, c, s

    def shade(cx, cy, rx, ry, deg, k=0.0, rim=0.55, cap=None):
        for x, y, u, w, rx_, ry_, c, s in each(cx, cy, rx, ry, deg):
            r = rx_ * (1 + k * w / ry_)
            if r <= 0: continue
            q = (u / r) ** 2 + (w / ry_) ** 2
            if q > 1: continue
            z = math.sqrt(1 - q); nu, nw = u / r, w / ry_
            nx, ny = nu * c - nw * s, nu * s + nw * c
            v = 0.25 + 0.75 * max(0, nx * L[0] + ny * L[1] + z * L[2])
            v *= (1 - rim) + rim * min(1, z * 1.8)
            t = 'hi' if v > 0.66 else ('mid' if v > 0.42 else 'lo')
            if cap == 'mid' and t == 'hi': t = 'mid'
            tone[y][x] = t; own[y][x] = cur[0]

    def fill(cx, cy, rx, ry, deg, t):
        for x, y, u, w, rx_, ry_, c, s in each(cx, cy, rx, ry, deg):
            if (u / rx_) ** 2 + (w / ry_) ** 2 <= 1:
                tone[y][x] = t; own[y][x] = cur[0]

    def dot(x, y, t):
        for yy in range(int(y * S), int((y + 1) * S)):
            for xx in range(int(x * S), int((x + 1) * S)):
                if 0 <= yy < GH and 0 <= xx < GW: tone[yy][xx] = t

    up = lift / S   # 頭まわりを上げる量（設計座標）。点の整数倍になる

    # 体: 下端は画面の外で固定し、上端だけを伸び縮みさせる
    bry = 10 * (1 + body)
    cur[0] = 'body'; shade(19, 38.5 + 10 - bry, 15.5, bry, -8, rim=0.6, cap='mid')

    # 奥のえら（右）: 広げると外へ伸び、先が上がる
    gx, gy, ga, gl = 33.5 + 0.9 * gill, 13.0 - up - 0.4 * gill, -20 - 9 * gill, 4.6 + 0.7 * gill
    cur[0] = 'gill'; shade(gx, gy, gl, 2.3, ga)
    for t in (3.0, 0.5):
        a_ = math.radians(ga)
        fx, fy = gx + math.cos(a_) * t, gy + math.sin(a_) * t
        fill(fx + 0.4 * gill, fy - 2.2 - 0.5 * gill, 0.7, 1.4 + 0.3 * gill, ga, 'mid')

    # 手前のえら（左）: 広げると外へ伸び、ふさが立つ
    nx_, ny_, na, nl = 6.5 - 1.0 * gill, 19.0 - up - 0.5 * gill, -8 + 8 * gill, 5.6 + 0.8 * gill
    shade(nx_, ny_, nl, 2.7, na)
    fl = 1.5 + 0.5 * gill
    for t in (-3.2, 0.0, 3.2):
        fill(nx_ + t, ny_ - 2.8 - 0.4 * gill - 0.12 * t * (1 + gill), 0.7, fl, 0, 'hi')
        fill(nx_ + t, ny_ + 2.9 + 0.2 * gill - 0.1 * t, 0.7, fl, 0, 'mid')

    cur[0] = 'head'; shade(20, 20.5 - up, 13.2, 11.0, T, k=0.16, rim=0.6)

    # 目（頭と一緒に上がる）
    if eyes_open:
        fill(14.2, 17.4 - up, 2.0, 2.2, 0, 'dark'); dot(13, 16 - up, 'hi')
        fill(27.6, 14.2 - up, 1.5, 1.7, 0, 'dark'); dot(27, 13 - up, 'hi')
    else:
        # 閉じた目: 下に丸い細い線
        fill(14.2, 18.4 - up, 2.2, 0.55, 0, 'dark'); fill(14.2, 17.9 - up, 1.6, 0.5, 0, 'dark')
        fill(27.6, 15.0 - up, 1.7, 0.5, 0, 'dark'); fill(27.6, 14.6 - up, 1.2, 0.45, 0, 'dark')

    # 口（中心は右上寄り。開くほど縦に伸ばし、少し下へずらす）
    if mouth <= 0.05:
        fill(23.0, 23.3 - up, 3.0, 0.55, T, 'dark')            # 閉じた口: 細い線
    else:
        ry = 0.9 + 2.3 * mouth; rx = 2.9 + 1.4 * min(mouth, 1.0) + 0.6 * max(0.0, mouth - 1.0)
        cy = 23.0 + 0.5 * (mouth - 1.0) - up
        fill(23.0, cy, rx, ry, T, 'hi')                    # 唇の縁
        fill(23.0, cy, rx - 1.1, ry - 1.0, T, 'dark')      # 口の中
        if mouth >= 0.5:                                    # 舌（奥の面）
            fill(23.6, cy + 0.8 * mouth, 0.5 + 1.1 * min(mouth, 1.2), 0.3 + 0.6 * min(mouth, 1.2), T, 'lo')

    # 頭が手前にあることを示す、点 1 つ分の隙間
    for y in range(GH):
        for x in range(GW):
            if own[y][x] in ('body', 'gill') and any(
                    0 <= y + dy < GH and 0 <= x + dx < GW and own[y + dy][x + dx] == 'head'
                    for dx in (-1, 0, 1) for dy in (-1, 0, 1)):
                tone[y][x] = None
    for y in range(GH):
        for x in range(GW):
            if tone[y][x] == 'dark': tone[y][x] = None
    return tone


def colour(t, gx, gy, cols, rows):
    """色: 段階の色 + 右下へ向かうゆるい暗さ + 文字ごとのわずかな色味の揺らぎ。"""
    r, g, b = BASE[t]
    f = 1.0 - 0.10 * max(0.0, min(1.0, (gx / cols + gy / rows) / 2))
    h = (gx * 73856093 ^ gy * 19349663) & 0xffff
    tr, tg, tb = TINTS[h % len(TINTS)]
    return tuple(max(0, min(255, int(v * f + d))) for v, d in ((r, tr), (g, tg), (b, tb)))


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else 'upaa-art'
    S = float(sys.argv[2]) if len(sys.argv) > 2 else 2.0
    os.makedirs(out, exist_ok=True)
    frames = [(f[0], draw(S, *f[1:])) for f in FRAMES]

    # すべてのフレームで同じ範囲を切り出す（切り替えても絵がずれないように、文字単位で揃える）
    GH, GW = len(frames[0][1]), len(frames[0][1][0])
    used = [(x, y) for _, tn in frames for y in range(GH) for x in range(GW) if tn[y][x]]
    x0 = min(x for x, _ in used) // 2 * 2; x1 = max(x for x, _ in used) // 2 * 2 + 2
    y0 = min(y for _, y in used) // 4 * 4; y1 = max(y for _, y in used) // 4 * 4 + 4
    W, H = x1 - x0, y1 - y0; cols, rows = W // 2, H // 4

    data = {"description": "upaa マスコットの点描。dots は行ごとの文字列で、1 点につき 2 文字（palette の番号の 16 進、'..' は点なし）。",
            "dot_width": W, "dot_height": H, "cell_cols": cols, "cell_rows": rows,
            "note": "1 文字（cell）は横 2 点 x 縦 4 点。色は cell ごとに 1 色で、点字版と同じ見た目になる。",
            "palette": [], "frames": []}
    pal = {}
    rendered = []
    for name, tn in frames:
        cells = {}
        ans_lines = []
        for cy in range(rows):
            line = ''; last = None
            for cx in range(cols):
                b = 0; ts = []
                for dx, dy, bit in BITS:
                    t = tn[y0 + cy * 4 + dy][x0 + cx * 2 + dx]
                    if t: b |= bit; ts.append(t)
                if not b:
                    line += ' '; continue
                cnt = Counter(ts); t = sorted(cnt, key=lambda k: (-cnt[k], ORDER.index(k)))[0]
                c = colour(t, cx, cy, cols, rows); cells[(cx, cy)] = c
                if c != last: line += '\x1b[38;2;%d;%d;%dm' % c; last = c
                line += chr(0x2800 + b)
            ans_lines.append(line.rstrip() + '\x1b[0m')
        with open(os.path.join(out, name + '.ans'), 'w', encoding='utf-8') as f:
            f.write('\n'.join(ans_lines) + '\n')
        dots = []
        for y in range(H):
            row = ''
            for x in range(W):
                if not tn[y0 + y][x0 + x]: row += '..'; continue
                c = cells[(x // 2, y // 4)]
                if c not in pal: pal[c] = len(pal); data["palette"].append('#%02x%02x%02x' % c)
                row += '%02x' % pal[c]
            dots.append(row)
        data["frames"].append({"name": name, "dots": dots})
        rendered.append((name, tn, cells))
    if len(pal) > 255: raise SystemExit('palette が 255 色を超えた')
    with open(os.path.join(out, 'frames.json'), 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=1)

    try:
        from PIL import Image, ImageDraw
    except ImportError:
        print('Pillow がないのでプレビューは作らない'); return
    P, D, pad = 9, 5, 24
    def img(tn, cells):
        im = Image.new('RGB', (W * P + 2 * pad, H * P + 2 * pad), (36, 40, 48)); d = ImageDraw.Draw(im)
        for y in range(H):
            for x in range(W):
                if tn[y0 + y][x0 + x]:
                    px, py = pad + x * P, pad + y * P
                    d.rectangle([px, py, px + D - 1, py + D - 1], fill=cells[(x // 2, y // 4)])
        return im
    ims = [img(tn, cells) for _, tn, cells in rendered]
    strip = Image.new('RGB', (sum(i.width for i in ims), ims[0].height), (36, 40, 48))
    xx = 0
    for i in ims: strip.paste(i, (xx, 0)); xx += i.width
    strip.save(os.path.join(out, 'preview.png'))
    by = {name: im for (name, _, _), im in zip(rendered, ims)}
    # クリック時: mouth-closed → half → open → wide（止める）→ open → half → settle → mouth-closed
    # 待機中: えらをゆっくり揺らし、ときどき瞬き
    seq = ['mouth-closed', 'mouth-half', 'mouth-open', 'mouth-wide', 'mouth-open', 'mouth-half', 'settle', 'mouth-closed',
           'idle-gill-a', 'mouth-closed', 'idle-gill-b', 'mouth-closed', 'blink', 'mouth-closed', 'idle-gill-a', 'mouth-closed', 'idle-gill-b', 'mouth-closed']
    dur = [600, 60, 60, 280, 70, 70, 90, 500,
           380, 380, 380, 380, 110, 400, 380, 380, 380, 600]
    by[seq[0]].save(os.path.join(out, 'preview.gif'), save_all=True,
                    append_images=[by[s] for s in seq[1:]], duration=dur, loop=0)
    print('%d frames, %d x %d dots (%d cols x %d rows), %d colours' % (len(FRAMES), W, H, cols, rows, len(pal)))


if __name__ == '__main__':
    main()
