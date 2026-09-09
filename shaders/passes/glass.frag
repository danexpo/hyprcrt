// hyprcrt pass: the glass - Lottes' warp, a vignette, rounded corners, black beyond the tube
uniform sampler2D tex;
uniform float warpX;
uniform float warpY;
uniform float vignette;
uniform sampler2D texA;   // the frame, for its alpha (window mode)
uniform int alphaFrom;
in vec2 v_texcoord;
layout(location = 0) out vec4 fragColor;
void main() {
    vec2  uv  = v_texcoord;
    float vig = crt_glass(uv, warpX, warpY, vignette);
    float a   = alphaFrom != 0 ? texture(texA, uv).a : 1.0;
    fragColor = vec4(texture(tex, uv).rgb * vig * a, a);
}
