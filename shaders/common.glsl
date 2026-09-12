// hyprcrt common.glsl - the tube model shared by the single-pass screen shader and the plugin passes.
// GLSL ES 3.00. No #version here: the file is spliced in after the version line by crt-gen / the plugin.
// MIT (c) 2026 Dan Expo. Warp, spot and mask after Timothy Lottes (public domain).

// ---- light ---------------------------------------------------------------------------------------------
vec3 crt_lin(vec3 c) { return pow(max(c, vec3(0.0)), vec3(2.2)); }
vec3 crt_enc(vec3 c, float invGamma) { return pow(clamp(c, 0.0, 1.0), vec3(invGamma)); }

// ---- the beam, horizontal: four taps of exp2(hard * d^2) around source column u (in source pixels),
//      normalised so a flat field stays flat; the red gun has its own (softer) width.
//      Weights only - the caller fetches the four taps at columns floor(u-0.5)-1 .. +2.
void crt_spot_weights(float u, float hard, float hardR, out vec4 wg, out vec4 wr, out float iu) {
    float uu = u - 0.5;
    iu = floor(uu);
    float fu = uu - iu;
    for (int k = 0; k < 4; k++) {
        float d = float(k - 1) - fu;
        wg[k] = exp2(hard * d * d);
        wr[k] = exp2(hardR * d * d);
    }
    wg /= (wg.x + wg.y + wg.z + wg.w);
    wr /= (wr.x + wr.y + wr.z + wr.w);
}

// ---- the beam, vertical: the weight of a scanline at distance d (0..1 in source rows) for a line whose
//      brightness is lum (0..1): a gaussian whose sigma grows with brightness, scaled by 1/(sigma*sqrt(pi))
//      so the line keeps its energy, capped so whites clip only a little.
float crt_scan_weight(float d, float lum, float sigDark, float sigBright, float cap) {
    float sig  = sigDark + (sigBright - sigDark) * lum;
    float gain = min(1.0 / (sig * 1.7724539), cap);
    return exp(-(d * d) / (sig * sig)) * gain;
}

// ---- the mask at a flat-space pixel p (physical pixels, pre-warp), mask pitch mp (pixels per stripe).
//      mode 0 none, 1 aperture grille (R G B columns), 2 slot mask (grille broken by a dark row every four,
//      staggered per triad), 3 shadow mask (the triad shifted one column every other row).
//      light/dark multipliers already carry the gain that folds the mask's mean back to one.
vec3 crt_mask(vec2 p, int mode, float mp, float light, float dark, float slotDim) {
    if (mode == 0)
        return vec3(1.0);
    float col = floor(p.x / mp);
    float row = floor(p.y / mp);
    if (mode == 3 && mod(row, 2.0) > 0.5)
        col += 1.0;
    float phase = mod(col, 3.0);
    vec3  m     = phase < 0.5 ? vec3(light, dark, dark) : (phase < 1.5 ? vec3(dark, light, dark) : vec3(dark, dark, light));
    if (mode == 2) {
        float triad = mod(floor(col / 3.0), 2.0);
        if (mod(mod(row, 4.0) + triad * 2.0, 4.0) > 2.5)
            m *= slotDim;
    }
    return m;
}

// ---- the glass: Lottes' warp on uv (0..1), a vignette toward the edges, rounded corners, black beyond the
//      tube. Returns the brightness factor (0 outside), warps uv in place.
float crt_glass(inout vec2 uv, float warpX, float warpY, float vignette) {
    vec2  p  = uv * 2.0 - 1.0;
    float wx = p.x * (1.0 + p.y * p.y * warpX), wy = p.y * (1.0 + p.x * p.x * warpY);
    float ax = abs(wx), ay = abs(wy);
    float r  = 0.0;
    if (ax > 0.94 && ay > 0.94) {
        float cx = (ax - 0.94) / 0.06, cy = (ay - 0.94) / 0.06;
        r        = cx * cx + cy * cy;
    }
    float p4  = p.x * p.x * p.x * p.x + p.y * p.y * p.y * p.y;
    float vig = 1.0 - vignette * p4 * 0.5;
    if (ax > 1.0 || ay > 1.0 || r > 1.0)
        vig = 0.0;
    else if (r > 0.85)
        vig *= (1.0 - r) / 0.15;
    uv = clamp(vec2(wx, wy) * 0.5 + 0.5, 0.0, 1.0);
    return clamp(vig, 0.0, 1.0);
}
