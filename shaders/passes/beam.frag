// hyprcrt pass: the horizontal spot - every source row at output width, four taps of exp2(hard * d^2)
uniform sampler2D tex;    // source (encoded)
uniform float hard;
uniform float hardR;
uniform float srcW;
in vec2 v_texcoord;
layout(location = 0) out vec4 fragColor;
void main() {
    vec4  wg, wr;
    float iu;
    crt_spot_weights(v_texcoord.x * srcW, hard, hardR, wg, wr, iu);
    vec3 acc = vec3(0.0);
    for (int k = 0; k < 4; k++) {
        float sx = clamp(iu - 1.0 + float(k), 0.0, srcW - 1.0);
        vec3  c  = crt_lin(texture(tex, vec2((sx + 0.5) / srcW, v_texcoord.y)).rgb);
        acc.r += c.r * wr[k];
        acc.gb += c.gb * wg[k];
    }
    fragColor = vec4(acc, 1.0);
}
