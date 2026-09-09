// hyprcrt pass: afterglow - the trail decays per channel and takes in a little of the new frame (mostly grey)
uniform sampler2D tex;    // source (encoded)
uniform sampler2D tex2;   // previous glow (linear)
uniform float glowIn;
uniform vec3 decay;
in vec2 v_texcoord;
layout(location = 0) out vec4 fragColor;
void main() {
    vec3  c    = crt_lin(texture(tex, v_texcoord).rgb);
    float lum  = dot(c, vec3(0.3, 0.6, 0.1));
    vec3  take = (c * 0.3 + lum * 0.7) * glowIn;
    vec3  prev = texture(tex2, v_texcoord).rgb;
    fragColor  = vec4(prev * decay + take, 1.0);
}
