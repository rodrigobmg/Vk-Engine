#include "common.glsl"

DECLARE_PER_FRAME_PARAMS();

layout(location=0) in float4 in_color;

layout(location=0) out float4 out_color;

void main() {
    out_color = in_color;
}
