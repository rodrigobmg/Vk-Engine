#include "common.glsl"
#include "fxaa.glsl"

DECLARE_PER_FRAME_PARAMS();

layout(set=1, binding=0) uniform sampler2D u_color_texture;
layout(set=1, binding=1) uniform usampler2D u_entity_guid_texture;
layout(set=1, binding=2) uniform usampler2D u_selected_entity_guid_texture;

layout(location=0) in float2 in_position;

layout(location=0) out float4 out_color;

float4 GetEntityOutline(float2 tex_coords, float2 texel_size) {
    float steps = u_frame_info.entity_outline_thickness * 3;
    float4 outline_color = float4(u_frame_info.entity_outline_color.rgb, 0);
    float2 inv_thickness = floor(u_frame_info.entity_outline_thickness) * texel_size;
    bool at_edge = ApproxEquals(tex_coords.x, 0, inv_thickness.x)
        || ApproxEquals(tex_coords.x, 1, inv_thickness.x)
        || ApproxEquals(tex_coords.y, 0, inv_thickness.y)
        || ApproxEquals(tex_coords.y, 1, inv_thickness.y);

    uint4 sampled_at_point = texture(u_selected_entity_guid_texture, tex_coords);
    if (at_edge || sampled_at_point == uint4(0)) {
        for (float i = 0; i < Tau; i += Tau / steps) {
            float2 offset = float2(sin(i), cos(i)) * texel_size * u_frame_info.entity_outline_thickness;
            uint4 sampled = texture(u_selected_entity_guid_texture, tex_coords + offset);
            if (sampled != uint4(0)) {
                // Render outline with a different alpha if it is covered by another mesh
                uint4 frontmost_entity = texture(u_entity_guid_texture, tex_coords + offset);
                if (frontmost_entity != uint4(0) && frontmost_entity != sampled) {
                    outline_color.a = u_frame_info.entity_outline_covered_alpha;
                } else {
                    outline_color.a = 1;
                }
                break;
            }
        }
    }

    return outline_color;
}

void main() {
    // float3 color = texture(u_color_texture, in_position).rgb;
    float3 color = FXAA(u_color_texture, in_position, 1 / u_frame_info.window_pixel_size).rgb;
    color = LinearTosRGB(color);
    color = ApplyToneMapping(color);

    float4 entity_outline = GetEntityOutline(in_position, 1 / u_frame_info.window_pixel_size);
    color = lerp(color, entity_outline.rgb, entity_outline.a);

    out_color = float4(color, 1);
}
