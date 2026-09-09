// hyprcrt pass: halation, vertical
uniform sampler2D tex;
uniform vec2 step;
in vec2 v_texcoord;
layout(location = 0) out vec4 fragColor;
void main() {
    vec2 uv  = v_texcoord;
    vec3 acc = texture(tex, uv).rgb * 7.0;
    acc += (texture(tex, uv - step).rgb + texture(tex, uv + step).rgb) * 6.0;
    acc += (texture(tex, uv - 2.0 * step).rgb + texture(tex, uv + 2.0 * step).rgb) * 3.0;
    acc += texture(tex, uv - 3.0 * step).rgb + texture(tex, uv + 3.0 * step).rgb;
    fragColor = vec4(acc / 27.0, 1.0);
}
