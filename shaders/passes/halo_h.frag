// hyprcrt pass: halation, horizontal - linear picture plus afterglow through the 7-tap kernel 1 3 6 7 6 3 1 / 27
uniform sampler2D tex;    // source (encoded)
uniform sampler2D tex2;   // glow (linear)
uniform vec2 step;
in vec2 v_texcoord;
layout(location = 0) out vec4 fragColor;
vec3 halo(vec2 uv) { return crt_lin(texture(tex, uv).rgb) + texture(tex2, uv).rgb; }
void main() {
    vec2 uv  = v_texcoord;
    vec3 acc = halo(uv) * 7.0;
    acc += (halo(uv - step) + halo(uv + step)) * 6.0;
    acc += (halo(uv - 2.0 * step) + halo(uv + 2.0 * step)) * 3.0;
    acc += halo(uv - 3.0 * step) + halo(uv + 3.0 * step);
    fragColor = vec4(acc / 27.0, 1.0);
}
