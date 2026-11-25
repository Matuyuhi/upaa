// 端末のセルを描く。1 セルを 1 インスタンスにして、背景とグリフの 2 回に分けて描く。
// 2 回に分けるのは、全角のグリフの右半分が隣のセルの背景で消えないようにするため。
#include <metal_stdlib>
using namespace metal;

// core/src/render/Cell.zig の Cell と同じ並び（24 バイト）。
struct Cell {
    ushort2 pos;
    ushort2 glyph_pos;
    ushort2 glyph_size;
    short2 glyph_offset;
    uchar4 fg;
    uchar4 bg;
};

struct Uniforms {
    float2 viewport_px;
    float2 cell_px;
    float2 atlas_px;
};

struct Varyings {
    float4 position [[position]];
    float4 color;
    float2 uv;
};

// 三角形ストリップ 4 頂点の四角形。
static float2 corner(uint vertex_id) {
    return float2(vertex_id & 1, vertex_id >> 1);
}

// 左上原点のピクセル座標をクリップ空間にする。
static float4 clip(float2 px, float2 viewport_px) {
    float2 ndc = px / viewport_px * 2.0 - 1.0;
    return float4(ndc.x, -ndc.y, 0.0, 1.0);
}

vertex Varyings background_vertex(uint vertex_id [[vertex_id]],
                                  uint instance_id [[instance_id]],
                                  const device Cell *cells [[buffer(0)]],
                                  constant Uniforms &u [[buffer(1)]]) {
    Cell cell = cells[instance_id];
    float2 px = (float2(cell.pos) + corner(vertex_id)) * u.cell_px;
    Varyings out;
    out.position = clip(px, u.viewport_px);
    out.color = float4(cell.bg) / 255.0;
    out.uv = float2(0.0);
    return out;
}

fragment float4 background_fragment(Varyings in [[stage_in]]) {
    return in.color;
}

vertex Varyings glyph_vertex(uint vertex_id [[vertex_id]],
                             uint instance_id [[instance_id]],
                             const device Cell *cells [[buffer(0)]],
                             constant Uniforms &u [[buffer(1)]]) {
    Cell cell = cells[instance_id];
    float2 size = float2(cell.glyph_size);
    float2 origin = float2(cell.pos) * u.cell_px + float2(cell.glyph_offset);
    float2 px = origin + corner(vertex_id) * size;
    Varyings out;
    // 大きさ 0 のグリフは面積が 0 になり、何も描かれない。
    out.position = clip(px, u.viewport_px);
    out.color = float4(cell.fg) / 255.0;
    out.uv = (float2(cell.glyph_pos) + corner(vertex_id) * size) / u.atlas_px;
    return out;
}

fragment float4 glyph_fragment(Varyings in [[stage_in]],
                               texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler nearest(coord::normalized, filter::nearest);
    float coverage = atlas.sample(nearest, in.uv).r;
    return float4(in.color.rgb, in.color.a * coverage);
}
