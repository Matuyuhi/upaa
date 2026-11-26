// Draws terminal cells. Each cell is one instance, drawn in two passes: background (including underline) and glyph.
// Two passes so that the right half of a full-width glyph is not erased by the neighboring cell's background.
#include <metal_stdlib>
using namespace metal;

// Same layout as Cell in core/src/render/Cell.zig (28 bytes).
struct Cell {
    ushort2 pos;
    ushort2 glyph_pos;
    ushort2 glyph_size;
    short2 glyph_offset;
    uchar4 fg;
    uchar4 bg;
    uint flags;
};

constant uint cell_underline = 1 << 0;

struct Uniforms {
    float2 viewport_px;
    float2 cell_px;
    float2 atlas_px;
    // From the top-left of the drawing target to the top-left of the grid (margin).
    float2 origin_px;
    // From the top edge of the cell to the top edge of the underline (x), and the underline thickness (y).
    float2 underline_px;
};

struct Varyings {
    float4 position [[position]];
    float4 color;
    float2 uv;
    // Used only when drawing the background. Vertical position within the cell, the underline band (top and bottom; an empty range if there is no underline), and color.
    float cell_y;
    float2 underline_band [[flat]];
    float4 underline_color [[flat]];
};

// Quad made of a 4-vertex triangle strip.
static float2 corner(uint vertex_id) {
    return float2(vertex_id & 1, vertex_id >> 1);
}

// Converts top-left-origin pixel coordinates to clip space.
static float4 clip(float2 px, float2 viewport_px) {
    float2 ndc = px / viewport_px * 2.0 - 1.0;
    return float4(ndc.x, -ndc.y, 0.0, 1.0);
}

vertex Varyings background_vertex(uint vertex_id [[vertex_id]],
                                  uint instance_id [[instance_id]],
                                  const device Cell *cells [[buffer(0)]],
                                  constant Uniforms &u [[buffer(1)]]) {
    Cell cell = cells[instance_id];
    float2 px = u.origin_px + (float2(cell.pos) + corner(vertex_id)) * u.cell_px;
    Varyings out;
    out.position = clip(px, u.viewport_px);
    out.color = float4(cell.bg) / 255.0;
    out.uv = float2(0.0);
    out.cell_y = corner(vertex_id).y * u.cell_px.y;
    bool underlined = (cell.flags & cell_underline) != 0;
    out.underline_band = underlined ? float2(u.underline_px.x, u.underline_px.x + u.underline_px.y) : float2(0.0);
    out.underline_color = float4(cell.fg) / 255.0;
    return out;
}

fragment float4 background_fragment(Varyings in [[stage_in]]) {
    bool on_underline = in.cell_y >= in.underline_band.x && in.cell_y < in.underline_band.y;
    return on_underline ? in.underline_color : in.color;
}

vertex Varyings glyph_vertex(uint vertex_id [[vertex_id]],
                             uint instance_id [[instance_id]],
                             const device Cell *cells [[buffer(0)]],
                             constant Uniforms &u [[buffer(1)]]) {
    Cell cell = cells[instance_id];
    float2 size = float2(cell.glyph_size);
    float2 origin = u.origin_px + float2(cell.pos) * u.cell_px + float2(cell.glyph_offset);
    float2 px = origin + corner(vertex_id) * size;
    Varyings out;
    // A glyph of size 0 has zero area, so nothing is drawn.
    out.position = clip(px, u.viewport_px);
    out.color = float4(cell.fg) / 255.0;
    out.uv = (float2(cell.glyph_pos) + corner(vertex_id) * size) / u.atlas_px;
    out.cell_y = 0.0;
    out.underline_band = float2(0.0);
    out.underline_color = float4(0.0);
    return out;
}

fragment float4 glyph_fragment(Varyings in [[stage_in]],
                               texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler nearest(coord::normalized, filter::nearest);
    float coverage = atlas.sample(nearest, in.uv).r;
    return float4(in.color.rgb, in.color.a * coverage);
}
