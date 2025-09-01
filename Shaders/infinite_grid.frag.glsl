// The Endless Grid by OGLDEV: https://www.youtube.com/watch?v=RqrkVmj-ntM

#include "common.glsl"

DECLARE_PER_FRAME_PARAMS();

layout(location=0) in float3 in_position;
layout(location=1) in float3 in_viewpoint_position;

layout(location=0) out float4 out_color;

void main() {
    float grid_size = 100;
    float min_cell_size = 0.1;
    float min_pixels_between_cells = 2;

    float2 dvx = float2(dFdx(in_position.x), dFdy(in_position.x));
    float2 dvz = float2(dFdx(in_position.z), dFdy(in_position.z));

    float2 dudv = float2(length(dvx), length(dvz));
    float l = length(dudv);

    float lod = max(0, Log10(l / min_cell_size * min_pixels_between_cells) + 1);
    float cell_size_lod0 = min_cell_size * pow(10, floor(lod));
    float cell_size_lod1 = cell_size_lod0 * 10;
    float cell_size_lod2 = cell_size_lod1 * 10;

    float line_thickness = 2;
    dudv *= line_thickness;

    float2 lod0_alpha_xz = float2(1) - mod(in_position.xz, cell_size_lod0) / dudv;
    lod0_alpha_xz = abs(clamp(lod0_alpha_xz, 0, 1) * 2 - float2(1));
    float lod0_alpha = max(1 - lod0_alpha_xz.x, 1 - lod0_alpha_xz.y);

    float2 lod1_alpha_xz = float2(1) - mod(in_position.xz, cell_size_lod1) / dudv;
    lod1_alpha_xz = abs(clamp(lod1_alpha_xz, 0, 1) * 2 - float2(1));
    float lod1_alpha = max(1 - lod1_alpha_xz.x, 1 - lod1_alpha_xz.y);

    float2 lod2_alpha_xz = float2(1) - mod(in_position.xz, cell_size_lod2) / dudv;
    lod2_alpha_xz = abs(clamp(lod2_alpha_xz, 0, 1) * 2 - float2(1));
    float lod2_alpha = max(1 - lod2_alpha_xz.x, 1 - lod2_alpha_xz.y);

    float lod_fade = fract(lod);

    float4 grid_color_thick_x = float4(1,0,0,0.8);
    float4 grid_color_thin_x = float4(1,0,0,0.3);

    float4 grid_color_thick_z = float4(0,0,1,0.8);
    float4 grid_color_thin_z = float4(0,0,1,0.3);

    float4 grid_color_thick = float4(1,1,1,0.8);
    float4 grid_color_thin = float4(0.6,0.6,0.6,0.3);

    float4 color_thick = grid_color_thick;
    float4 color_thin = grid_color_thin;

    if (abs(in_position.x / dudv.x) < 1) {
        color_thick = grid_color_thick_z;
        color_thin = grid_color_thin_z;
    }
    if (abs(in_position.z / dudv.y) < 1) {
        color_thick = grid_color_thick_x;
        color_thin = grid_color_thin_x;
    }

    if (lod2_alpha > 0) {
        out_color = color_thick;
        out_color.a *= lod2_alpha;
    } else if (lod1_alpha > 0) {
        out_color = mix(color_thick, color_thin, lod_fade);
        out_color.a *= lod1_alpha;
    } else {
        out_color = color_thin;
        out_color.a *= lod0_alpha * (1 - lod_fade);
    }

    float alpha_falloff = (1 - clamp(length(in_position.xz - in_viewpoint_position.xz) / grid_size, 0, 1));
    out_color.a *= alpha_falloff;

    if (out_color.a == 0) {
        discard;
    }
}
