// hyprcrt pass: the beam down the screen - the two nearest scanlines, each a gaussian whose width follows its
// brightness, scaled to keep its energy; the mask; the halation; the encode
uniform sampler2D tex;    // line: every source row through the spot, at output width (linear)
uniform sampler2D tex2;   // halo (linear, source resolution)
uniform vec2 outSize;
uniform float pitch;
uniform float srcH;
uniform float haloAmt;
uniform float sigDark;
uniform float sigBright;
uniform float cap;
uniform int flatLines;
uniform int maskMode;
uniform float maskPitch;
uniform float maskLight;
uniform float maskDark;
uniform float slotDim;
uniform float invGamma;
uniform float gain;
uniform sampler2D texA;   // the frame, for its alpha (window mode)
uniform int alphaFrom;
in vec2 v_texcoord;
layout(location = 0) out vec4 fragColor;
void main() {
    vec2  px = v_texcoord * outSize;
    float v  = px.y / pitch - 0.5;
    float r0 = floor(v), d0 = v - r0, d1 = 1.0 - d0;
    float y0 = (clamp(r0, 0.0, srcH - 1.0) + 0.5) / srcH, y1 = (clamp(r0 + 1.0, 0.0, srcH - 1.0) + 0.5) / srcH;
    vec3  a  = texture(tex, vec2(v_texcoord.x, y0)).rgb, b = texture(tex, vec2(v_texcoord.x, y1)).rgb;
    float wa, wb;
    if (flatLines != 0) {
        wa = (1.0 - d0) * (1.0 - haloAmt);
        wb = d0 * (1.0 - haloAmt);
    } else {
        float la = clamp(max(a.r, max(a.g, a.b)), 0.0, 1.0), lb = clamp(max(b.r, max(b.g, b.b)), 0.0, 1.0);
        wa       = crt_scan_weight(d0, la, sigDark, sigBright, cap) * (1.0 - haloAmt);
        wb       = crt_scan_weight(d1, lb, sigDark, sigBright, cap) * (1.0 - haloAmt);
    }
    vec3 val = a * wa + b * wb + texture(tex2, v_texcoord).rgb * haloAmt;
    val *= crt_mask(px, maskMode, maskPitch, maskLight, maskDark, slotDim);
    vec3 rgb = crt_enc(val * gain, invGamma);
    float alpha = alphaFrom != 0 ? texture(texA, v_texcoord).a : 1.0;
    fragColor   = vec4(rgb * alpha, alpha);
}
