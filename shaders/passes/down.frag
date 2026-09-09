// hyprcrt pass: virtual source - the screen boxed down by the pitch (encoded-space mean of p x p pixels)
uniform sampler2D tex;
uniform vec2 srcSize;   // physical pixels of the frame
uniform vec2 outSize;   // virtual source size
uniform int pitch;
in vec2 v_texcoord;
layout(location = 0) out vec4 fragColor;
void main() {
    vec2 o   = floor(v_texcoord * outSize);
    vec3 acc = vec3(0.0);
    for (int j = 0; j < pitch; j++)
        for (int i = 0; i < pitch; i++)
            acc += texture(tex, (o * float(pitch) + vec2(float(i) + 0.5, float(j) + 0.5)) / srcSize).rgb;
    fragColor = vec4(acc / float(pitch * pitch), 1.0);
}
