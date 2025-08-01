layout(location=0) in vec2 v_position;
layout(location=1) in vec2 v_tex_coords;
layout(location=2) in vec4 v_color;

layout(location=0) out vec2 out_tex_coords;
layout(location=1) out vec4 out_color;

layout(set=0, binding=0, std140) uniform Projection {
    mat4 u_projection;
};

void main() {
    out_tex_coords = v_tex_coords;
    out_color = v_color;

    gl_Position = u_projection * vec4(v_position, 0, 1);
    gl_Position.y *= -1;
}
