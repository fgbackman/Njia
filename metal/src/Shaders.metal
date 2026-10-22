#include <metal_stdlib>
using namespace metal;

// Mirrors `Uniforms` in Renderer.swift.
struct U {
    float4x4 viewProj;
    float4x4 shadowVP[2];
    float4 camPos;       // xyz eye, w time in seconds
    float4 camRight;     // xyz right * tan(fovX/2)
    float4 camUp;        // xyz up * tan(fovY/2)
    float4 camFwd;
    float4 sunDir;       // xyz toward the sun
    float4 sunColor;     // rgb sun irradiance at the ground, w exposure
    float4 world;        // x heightmap half extent, y grass radius
    float4 grassOrigin;  // z fog density
    float4 frustum[4];   // normalized side planes
    float4 soilA;
    float4 soilB;
    float4 grassDry;
    float4 biome;        // x grass cover bias, y grass height, z green bias, w cloud bias
    float4 real;         // x 1 when the stage uses measured terrain and satellite imagery, y sea level, z bare-ground brightness
};

// ---------------------------------------------------------------- noise

static float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

static float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 w = f * f * (3.0 - 2.0 * f);
    float a = hash12(i);
    float b = hash12(i + float2(1, 0));
    float c = hash12(i + float2(0, 1));
    float d = hash12(i + float2(1, 1));
    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}

static float fbm(float2 p, int oct) {
    float amp = 0.5, sum = 0.0, norm = 0.0;
    for (int i = 0; i < oct; i++) {
        sum += amp * vnoise(p);
        norm += amp;
        p = p * 2.03 + float2(17.1, 9.2);
        amp *= 0.5;
    }
    return sum / norm;
}

// ---------------------------------------------------------------- world fields (path must match World.swift)

static float pathMask(float2 xz) {
    float px = 60.0 * sin(xz.y / 180.0) + 25.0 * sin(xz.y / 67.0 + 1.3);
    float slope = (60.0 / 180.0) * cos(xz.y / 180.0) + (25.0 / 67.0) * cos(xz.y / 67.0 + 1.3);
    float d = abs(xz.x - px) / sqrt(1.0 + slope * slope);
    d += (vnoise(xz * 0.7) - 0.5) * 0.9;
    return 1.0 - smoothstep(0.7, 1.9, d);
}

static float moisture(float2 xz) {
    return fbm(xz * 0.0035 + 31.7, 3);
}

static float grassCover(float2 xz, float bias) {
    return smoothstep(0.28, 0.5, fbm(xz * 0.03 + 7.3, 3) + bias);
}

// Satellite colour at a world position: the 2 km image near the origin, the 32 km one beyond.
static float3 satColor(float2 xz, texture2d<float> nearSat, texture2d<float> farSat, sampler cs) {
    float3 n = nearSat.sample(cs, (xz + 1024.0) / 2048.0).rgb;
    float3 f = farSat.sample(cs, (xz + 16000.0) / 32000.0).rgb;
    return mix(n, f, smoothstep(900.0, 1024.0, max(abs(xz.x), abs(xz.y)))) * 0.9;
}

// How vegetated a satellite colour looks: dark and not water.
static float satVeg(float3 c, float bare) {
    float water = step(c.r * 1.25, c.b);
    return (1.0 - smoothstep(bare * 0.36, bare, dot(c, float3(0.3, 0.6, 0.1)))) * (1.0 - water);
}

// Fine relief of bare ground: lumps, grit and grain. Only evaluated near the camera.
static float groundRelief(float2 xz) {
    return fbm(xz * 2.2, 4) * 0.6 + vnoise(xz * 11.0) * 0.25 + vnoise(xz * 37.0) * 0.15;
}

// ---------------------------------------------------------------- sky

static float3 skyLookup(texture2d<float> lut, sampler s, float3 d) {
    float u = atan2(d.z, d.x) * 0.15915494 + 0.5;
    float v = sqrt(saturate(d.y));
    return lut.sample(s, float2(u, v), level(0)).rgb;
}

static float3 skyAmbient(texture2d<float> lut, sampler s) {
    float3 a = skyLookup(lut, s, float3(0, 1, 0)) * 2.0;
    a += skyLookup(lut, s, float3(0.857, 0.515, 0));
    a += skyLookup(lut, s, float3(-0.857, 0.515, 0));
    a += skyLookup(lut, s, float3(0, 0.515, 0.857));
    a += skyLookup(lut, s, float3(0, 0.515, -0.857));
    return a / 6.0;
}

static float2 raySphere(float3 r0, float3 rd, float sr) {
    float b = 2.0 * dot(rd, r0);
    float c = dot(r0, r0) - sr * sr;
    float d = b * b - 4.0 * c;
    if (d < 0.0) return float2(1e9, -1e9);
    float sq = sqrt(d);
    return float2((-b - sq) * 0.5, (-b + sq) * 0.5);
}

// Single-scattering Rayleigh + Mie atmosphere, ray-marched.
static float3 atmosphere(float3 r, float3 sun) {
    const float rPlanet = 6371e3, rAtmos = 6471e3;
    const float3 kRlh = float3(5.5e-6, 13.0e-6, 22.4e-6);
    const float kMie = 21e-6, shRlh = 8000.0, shMie = 1200.0, g = 0.758, iSun = 22.0;
    const int iSteps = 24, jSteps = 8;
    float3 r0 = float3(0, rPlanet + 100.0, 0);

    float tEnd = raySphere(r0, r, rAtmos).y;
    float iStep = tEnd / float(iSteps);
    float iTime = 0.0;
    float3 totalRlh = float3(0), totalMie = float3(0);
    float iOdRlh = 0.0, iOdMie = 0.0;
    float mu = dot(r, sun), mumu = mu * mu, gg = g * g;
    float pRlh = 3.0 / (16.0 * M_PI_F) * (1.0 + mumu);
    float pMie = 3.0 / (8.0 * M_PI_F) * ((1.0 - gg) * (mumu + 1.0)) / (pow(1.0 + gg - 2.0 * mu * g, 1.5) * (2.0 + gg));

    for (int i = 0; i < iSteps; i++) {
        float3 iPos = r0 + r * (iTime + iStep * 0.5);
        float iHeight = length(iPos) - rPlanet;
        float odStepRlh = exp(-iHeight / shRlh) * iStep;
        float odStepMie = exp(-iHeight / shMie) * iStep;
        iOdRlh += odStepRlh;
        iOdMie += odStepMie;

        float jStep = raySphere(iPos, sun, rAtmos).y / float(jSteps);
        float jTime = 0.0, jOdRlh = 0.0, jOdMie = 0.0;
        for (int j = 0; j < jSteps; j++) {
            float3 jPos = iPos + sun * (jTime + jStep * 0.5);
            float jHeight = length(jPos) - rPlanet;
            jOdRlh += exp(-jHeight / shRlh) * jStep;
            jOdMie += exp(-jHeight / shMie) * jStep;
            jTime += jStep;
        }
        float3 attn = exp(-(kMie * (iOdMie + jOdMie) + kRlh * (iOdRlh + jOdRlh)));
        totalRlh += odStepRlh * attn;
        totalMie += odStepMie * attn;
        iTime += iStep;
    }
    return iSun * (pRlh * kRlh * totalRlh + pMie * kMie * totalMie);
}

// ---------------------------------------------------------------- lighting

static float shadowTerm(float3 P, float3 N, constant U &u, depth2d_array<float> smap, sampler cmp) {
    for (int c = 0; c < 2; c++) {
        float texel = (c == 0) ? 0.025 : 0.21;
        float3 Pb = P + N * texel * 1.6 + u.sunDir.xyz * texel * 0.6;
        float3 q = (u.shadowVP[c] * float4(Pb, 1.0)).xyz;
        float2 uv = float2(q.x * 0.5 + 0.5, 0.5 - q.y * 0.5);
        if (all(uv > 0.004) && all(uv < 0.996) && q.z < 1.0) {
            float bias = (c == 0) ? 0.00025 : 0.0003;
            float s = 0.0;
            for (int y = -1; y <= 1; y++) {
                for (int x = -1; x <= 1; x++) {
                    s += smap.sample_compare(cmp, uv + float2(x, y) / 4096.0, c, q.z - bias, level(0));
                }
            }
            return s / 9.0;
        }
    }
    return 1.0;
}

static float3 shade(float3 albedo, float3 N, float sh, float ao, float trans, float3 V,
                    constant U &u, texture2d<float> lut, sampler ls) {
    float3 L = u.sunDir.xyz;
    float3 sunE = u.sunColor.rgb * 0.3183;
    float3 skyA = skyAmbient(lut, ls);
    float3 bounce = float3(0.30, 0.22, 0.12) * (sunE * saturate(L.y) + skyA);
    float3 amb = mix(bounce, skyA, N.y * 0.5 + 0.5);
    float ndl = saturate(dot(N, L));
    float back = pow(saturate(dot(-V, L)), 3.0) * trans;
    return albedo * (sunE * sh * (ndl + back) + amb * ao);
}

static float3 applyFog(float3 col, float3 P, constant U &u, texture2d<float> lut, sampler ls) {
    float3 d = P - u.camPos.xyz;
    float dist = length(d);
    float3 rd = d / dist;
    float hAvg = max(0.0, (P.y + u.camPos.y) * 0.5);
    float f = 1.0 - exp(-dist * u.grassOrigin.z * exp(-hAvg / 1800.0));
    float3 fc = skyLookup(lut, ls, normalize(float3(rd.x, max(rd.y, 0.0) + 0.03, rd.z)));
    return mix(col, fc, f);
}

static float3 aces(float3 x) {
    return saturate((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14));
}

// ---------------------------------------------------------------- fullscreen passes

struct QuadV {
    float4 position [[position]];
    float2 uv;
};

vertex QuadV quad_vs(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    QuadV o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

fragment float4 skylut_fs(QuadV in [[stage_in]], constant U &u [[buffer(1)]]) {
    float y = in.uv.y * in.uv.y;
    float r = sqrt(max(0.0, 1.0 - y * y));
    float phi = (in.uv.x - 0.5) * 6.2831853;
    float3 d = float3(r * cos(phi), y, r * sin(phi));
    return float4(atmosphere(d, u.sunDir.xyz), 1.0);
}

fragment float4 sky_fs(QuadV in [[stage_in]], constant U &u [[buffer(1)]],
                       texture2d<float> lut [[texture(0)]], sampler ls [[sampler(0)]]) {
    float2 ndc = float2(in.uv.x * 2.0 - 1.0, 1.0 - in.uv.y * 2.0);
    float3 rd = normalize(u.camFwd.xyz + ndc.x * u.camRight.xyz + ndc.y * u.camUp.xyz);
    float3 sun = u.sunDir.xyz;
    float3 col = skyLookup(lut, ls, normalize(float3(rd.x, max(rd.y, 0.0), rd.z)));

    float mu = dot(rd, sun);
    col += smoothstep(0.999970, 0.999978, mu) * u.sunColor.rgb * 40.0;
    col += u.sunColor.rgb * (pow(saturate(mu), 2000.0) * 1.5 + pow(saturate(mu), 180.0) * 0.06);

    if (rd.y > 0.004) {
        float t = (2600.0 - u.camPos.y) / rd.y;
        float2 cp = (u.camPos.xz + rd.xz * t) * 0.0005 + u.camPos.w * float2(0.004, 0.0015);
        cp += (float2(fbm(cp * 0.7 + 3.0, 2), fbm(cp * 0.7 + 11.0, 2)) - 0.5) * 0.9;
        float n = fbm(cp, 6) * (0.55 + 0.9 * fbm(cp * 0.21 + 5.0, 2));
        float n2 = fbm(cp + sun.xz * 0.07, 4) * (0.55 + 0.9 * fbm((cp + sun.xz * 0.07) * 0.21 + 5.0, 2));
        n += u.biome.w;
        float cov = smoothstep(0.47, 0.70, n);
        float lightf = saturate(0.6 + (n - n2) * 5.0);
        float3 amb = skyLookup(lut, ls, float3(0, 1, 0));
        float3 ccol = u.sunColor.rgb * 0.3183 * (0.25 + 0.75 * lightf) * (0.8 + 0.9 * pow(saturate(mu), 6.0)) + amb * 0.9;
        ccol *= mix(1.0, 0.6, smoothstep(0.55, 0.85, n));   // thick cloud is grey underneath
        col = mix(col, ccol, cov * exp(-t * 0.000035) * 0.9);
    }
    return float4(col, 1.0);
}

fragment float4 post_fs(QuadV in [[stage_in]], constant U &u [[buffer(1)]],
                        texture2d<float> hdr [[texture(0)]], sampler ls [[sampler(0)]]) {
    float3 c = hdr.sample(ls, in.uv).rgb * u.sunColor.w;
    float2 q = in.uv - 0.5;
    c *= 1.0 - dot(q, q) * 0.35;
    c = aces(c);
    c += (hash12(in.position.xy + fract(u.camPos.w) * 61.0) - 0.5) / 255.0;
    return float4(c, 1.0);
}

// ---------------------------------------------------------------- terrain

struct TerrainIn {
    float3 position [[attribute(0)]];
    float3 normal [[attribute(1)]];
};

struct TerrainV {
    float4 position [[position]];
    float3 wpos;
    float3 normal;
};

vertex TerrainV terrain_vs(TerrainIn in [[stage_in]], constant U &u [[buffer(1)]]) {
    TerrainV o;
    o.position = u.viewProj * float4(in.position, 1.0);
    o.wpos = in.position;
    o.normal = in.normal;
    return o;
}

// Shadow passes are orthographic: clamping z pancakes casters that sit in front of the near plane.
vertex float4 terrain_shadow_vs(TerrainIn in [[stage_in]], constant U &u [[buffer(1)]]) {
    float4 p = u.viewProj * float4(in.position, 1.0);
    p.z = max(p.z, 0.0001);
    return p;
}

fragment float4 terrain_fs(TerrainV in [[stage_in]], constant U &u [[buffer(1)]],
                           texture2d<float> lut [[texture(0)]], depth2d_array<float> smap [[texture(1)]],
                           texture2d<float> nearSat [[texture(2)]], texture2d<float> farSat [[texture(3)]],
                           texture2d<float> mapMask [[texture(5)]],
                           sampler ls [[sampler(0)]], sampler cmp [[sampler(1)]], sampler cs [[sampler(2)]]) {
    float3 P = in.wpos;
    float2 xz = P.xz;
    float3 G = normalize(in.normal);
    bool real = u.real.x > 0.5;
    float3 sat = satColor(xz, nearSat, farSat, cs);
    float3 toCam = u.camPos.xyz - P;
    float dist = length(toCam);
    float3 V = toCam / dist;

    float nearF = saturate(1.0 - dist / 45.0);
    float3 N = G;
    float relief = 0.5;
    if (nearF > 0.0) {
        float e = 0.03;
        relief = groundRelief(xz);
        float rx = groundRelief(xz + float2(e, 0));
        float rz = groundRelief(xz + float2(0, e));
        N = normalize(G + float3(relief - rx, 0.0, relief - rz) * (0.035 / e) * nearF);
    }

    float rock = smoothstep(0.16, 0.32, 1.0 - G.y + (fbm(xz * 0.05, 2) - 0.5) * 0.12);
    float pm = (dist < 900.0 && !real) ? pathMask(xz) : 0.0;
    float green = smoothstep(0.50, 0.68, moisture(xz) + u.biome.z);
    float cover = grassCover(xz, u.biome.x) * (1.0 - pm) * (1.0 - rock);
    // Mapped features inside the walkable square: paved road, dirt road, water, building footprint.
    float4 mapped = (real && all(abs(xz) < 1024.0)) ? mapMask.sample(cs, (xz + 1024.0) / 2048.0) : float4(0);
    if (real) cover *= satVeg(sat, u.real.z) * step(0.4, P.y - u.real.y) * (1.0 - saturate(mapped.r + mapped.g + mapped.b + mapped.a));

    float3 soil = mix(u.soilA.rgb, u.soilB.rgb, fbm(xz * 0.35, 3));
    if (real) soil = sat * (0.85 + 0.3 * fbm(xz * 0.35, 3));
    float3 pathCol = mix(u.soilB.rgb, float3(0.40, 0.34, 0.27), 0.2) * (0.85 + 0.35 * fbm(xz * 0.6, 3));
    if (nearF > 0.0) {
        // Hollows are darker and damper, high spots dusty; scattered pebbles on top.
        float grain = mix(1.0, 0.55 + 0.9 * relief, nearF);
        soil *= grain;
        pathCol *= grain;
        float pebble = smoothstep(0.86, 0.91, vnoise(xz * 19.0 + 4.7)) * nearF;
        float3 stone = mix(float3(0.12, 0.105, 0.09), float3(0.25, 0.22, 0.19), hash12(floor(xz * 19.0 + 4.7)));
        soil = mix(soil, stone, pebble * 0.8);
        pathCol = mix(pathCol, stone, pebble);
    }
    float3 grassFar = mix(u.grassDry.rgb * 0.85, float3(0.085, 0.115, 0.04), green * 0.7) * (0.85 + 0.3 * fbm(xz * 0.15, 3));
    // Standing grass seen from afar: the satellite's colour, darkened and streaked so it does not read as bare sand.
    if (real) grassFar = sat * (0.5 + 0.28 * fbm(xz * 0.09, 3) + 0.3 * fbm(xz * float2(0.9, 0.35), 3) * saturate(1.0 - dist / 700.0)) * float3(1.0, 0.96, 0.8);
    float3 litter = mix(soil, grassFar * 0.8, 0.45);

    float R = u.world.y;
    float3 ground = mix(soil, mix(litter, grassFar, smoothstep(R * 0.35, R * 0.9, dist)), cover);
    ground = mix(ground, pathCol, pm);
    float3 rockCol = mix(float3(0.20, 0.18, 0.16), float3(0.30, 0.26, 0.21), fbm(xz * 0.4 + P.y * 0.3, 4));
    ground = mix(ground, real ? mix(rockCol, sat, 0.6) : rockCol, rock);
    if (real) {
        // Past the imagery (16 km) the skyline is coloured by altitude: forest belt, bare rock, ice.
        float alt = P.y - u.real.y;
        float3 hz = mix(u.soilB.rgb, u.grassDry.rgb, 0.5) * 0.8;
        hz = mix(hz, float3(0.035, 0.07, 0.03), smoothstep(1700.0, 2200.0, alt) * (1.0 - smoothstep(2900.0, 3400.0, alt)));
        hz = mix(hz, float3(0.17, 0.15, 0.14), smoothstep(3000.0, 3800.0, alt));
        hz = mix(hz, float3(0.85, 0.87, 0.90), smoothstep(5100.0, 5500.0, alt + (fbm(xz * 0.0015, 3) - 0.5) * 500.0));
        ground = mix(ground, hz, smoothstep(15000.0, 16500.0, max(abs(xz.x), abs(xz.y))));
    }
    float grit = 0.85 + 0.3 * relief;
    ground = mix(ground, mix(u.soilB.rgb, sat * 1.3, 0.5) * grit, mapped.g);
    ground = mix(ground, float3(0.045, 0.045, 0.05) * grit, mapped.r);
    ground = mix(ground, float3(0.02, 0.05, 0.05), mapped.b);

    // Mountain belts: forest, bare rock, snow.
    if (!real) {
        ground = mix(ground, float3(0.05, 0.09, 0.04), smoothstep(250.0, 700.0, P.y) * (1.0 - rock));
        ground = mix(ground, float3(0.20, 0.17, 0.15), smoothstep(1300.0, 1900.0, P.y));
        ground = mix(ground, float3(0.85, 0.87, 0.90), smoothstep(2300.0, 2550.0, P.y + fbm(xz * 0.004, 3) * 300.0 - 150.0));
    }

    // Ground under standing grass sits in the blades' shade.
    float farGrass = cover * smoothstep(R * 0.5, R * 0.95, dist);
    float under = cover - farGrass;
    // Beyond the drawn blades the surface stands in for upright grass, which catches low sun.
    N = normalize(mix(N, normalize(G + float3(u.sunDir.x, 0.0, u.sunDir.z) * 0.9), farGrass * 0.35));
    // Distant grass also shades itself, as the drawn blades do.
    float sh = shadowTerm(P, G, u, smap, cmp) * mix(1.0, 0.3, under) * mix(1.0, 0.72, farGrass);
    float3 col = shade(ground, N, sh, mix(1.0, 0.55, under), 0.0, V, u, lut, ls);
    if (mapped.b > 0.01) {
        // Still inland water: mostly a mirror of the sky.
        float fres = 0.04 + 0.96 * pow(1.0 - saturate(V.y), 5.0);
        float ripple = 0.06 * saturate(1.0 - dist / 80.0);
        float3 R = reflect(-V, normalize(float3((relief - 0.5) * ripple, 1.0, (vnoise(xz * 3.0 + u.camPos.w) - 0.5) * ripple)));
        col = mix(col, mix(col, skyLookup(lut, ls, normalize(float3(R.x, abs(R.y), R.z))), fres), mapped.b);
    }
    return float4(applyFog(col, P, u, lut, ls), 1.0);
}

// ---------------------------------------------------------------- instanced meshes (trees, shrubs, rocks)

struct MeshIn {
    float3 position [[attribute(0)]];
    float3 normal [[attribute(1)]];
    float2 uv [[attribute(2)]];
    // x material: 0 bark, 1 leaf, 2 rock, 3 paint, 5 house wall, 6 commercial wall, 7 roof.
    // The rest depends on it: seed and sway for plants; colour for buildings.
    float4 extra [[attribute(3)]];
};

struct Inst {
    float4 a;   // xyz position, w scale
    float4 b;   // cos yaw, sin yaw, seed
    float4 c;   // people: frame in the pose table, a second frame, how far to blend towards it, skin lightening
    float4 d;   // people: where the head joint is, and how far the head is turned
};

struct MeshV {
    float4 position [[position]];
    float3 wpos;
    float3 normal;
    float2 uv;
    float4 extra;
    float seed [[flat]];
};

static float3 instancePos(MeshIn in, Inst I, float time, float3 &n) {
    float3 p = in.position;
    n = in.normal;
    float3 lp = p * I.a.w;
    if (in.extra.x < 1.5) {
        lp.xz += in.extra.z * 0.035 * float2(sin(time * 1.3 + I.b.z * 40.0 + lp.y), cos(time * 1.1 + I.b.z * 17.0 + lp.x * 0.8));
    }
    n = float3(I.b.x * n.x + I.b.y * n.z, n.y, -I.b.y * n.x + I.b.x * n.z);
    return float3(I.b.x * lp.x + I.b.y * lp.z, lp.y, -I.b.y * lp.x + I.b.x * lp.z) + I.a.xyz;
}

static float leafValue(float2 uv, float seed) {
    float r = length(uv - 0.5) * 2.0;
    float n = vnoise(uv * 13.0 + seed * 57.0) * 0.6 + vnoise(uv * 29.0 + seed * 91.0) * 0.4;
    return n * (1.3 - r * r);
}

vertex MeshV mesh_vs(MeshIn in [[stage_in]], uint iid [[instance_id]],
                     constant U &u [[buffer(1)]], const device Inst *inst [[buffer(2)]]) {
    Inst I = inst[iid];
    MeshV o;
    float3 n;
    o.wpos = instancePos(in, I, u.camPos.w, n);
    o.position = u.viewProj * float4(o.wpos, 1.0);
    o.normal = n;
    o.uv = in.uv;
    o.extra = in.extra;
    o.seed = I.b.z;
    return o;
}

struct MeshShadowV {
    float4 position [[position]];
    float2 uv;
    float2 matSeed;
};

vertex MeshShadowV mesh_shadow_vs(MeshIn in [[stage_in]], uint iid [[instance_id]],
                                  constant U &u [[buffer(1)]], const device Inst *inst [[buffer(2)]]) {
    MeshShadowV o;
    float3 n;
    o.position = u.viewProj * float4(instancePos(in, inst[iid], u.camPos.w, n), 1.0);
    o.position.z = max(o.position.z, 0.0001);
    o.uv = in.uv;
    o.matSeed = in.extra.xy;
    return o;
}

fragment void mesh_shadow_fs(MeshShadowV in [[stage_in]]) {
    if (in.matSeed.x > 0.5 && in.matSeed.x < 1.5 && leafValue(in.uv, in.matSeed.y) < 0.5) discard_fragment();
}

fragment float4 mesh_fs(MeshV in [[stage_in]], constant U &u [[buffer(1)]],
                        texture2d<float> lut [[texture(0)]], depth2d_array<float> smap [[texture(1)]],
                        sampler ls [[sampler(0)]], sampler cmp [[sampler(1)]]) {
    float3 P = in.wpos;
    float3 V = normalize(u.camPos.xyz - P);
    float dist = length(u.camPos.xyz - P);
    float3 N = normalize(in.normal);
    int mat = int(in.extra.x + 0.5);
    float3 albedo;
    float alpha = 1.0, trans = 0.0;
    float3 gloss = float3(0.0);   // specular strength, shininess, subsurface
    float glass = 0.0;

    if (mat == 1) {
        float val = leafValue(in.uv, in.extra.y);
        alpha = saturate((val - 0.5) * 12.0 + 0.5);
        if (alpha < 0.08) discard_fragment();
        albedo = mix(float3(0.055, 0.085, 0.025), float3(0.12, 0.15, 0.045), fract(in.extra.y * 7.3 + in.seed * 3.1));
        albedo *= 0.6 + 0.7 * val;
        trans = 0.5;
    } else if (mat == 0) {
        float streak = fbm(float2((P.x + P.z) * 14.0, P.y * 2.5), 3);
        albedo = mix(float3(0.085, 0.07, 0.055), float3(0.21, 0.18, 0.15), streak);
    } else if (mat == 3) {
        const float3 paint[10] = { float3(0.62, 0.58, 0.48), float3(0.50, 0.045, 0.035), float3(0.78, 0.77, 0.74), float3(0.03, 0.03, 0.035),
                                  float3(0.66, 0.63, 0.56), float3(0.55, 0.47, 0.38), float3(0.72, 0.70, 0.66),
                                  float3(0.16, 0.15, 0.15), float3(0.33, 0.13, 0.09), float3(0.20, 0.11, 0.065) };
        albedo = paint[clamp(int(in.extra.y + 0.5), 0, 9)] * (0.9 + 0.2 * fbm(P.xz * 3.0 + P.y * 2.0, 3));
    } else if (mat == 5 || mat == 6) {
        float3 base = in.extra.yzw;
        float2 along = normalize(float2(-N.z, N.x) + 1e-5);
        float s = dot(P.xz, along);                    // metres along the wall
        float near = saturate(1.0 - dist / 70.0);
        albedo = base * (0.8 + 0.3 * fbm(float2(s * 0.6, P.y * 0.3), 4));
        if (base.r > base.g * 1.5 && base.r > 0.12) {
            // Brick: courses with staggered joints.
            float row = P.y / 0.085;
            float2 b = float2(fract(s / 0.23 + 0.5 * floor(row)), fract(row));
            float mortar = max(step(0.93, b.x), step(0.86, b.y));
            albedo = mix(albedo, float3(dot(albedo, float3(0.3, 0.6, 0.1))), 0.3) * (0.7 + 0.25 * hash12(floor(float2(s / 0.23 + 0.5 * floor(row), row))));
            albedo = mix(albedo, float3(0.30, 0.28, 0.25), mortar * near * 0.7);
        } else {
            // Plaster over blockwork: faint courses, hairline cracks.
            float row = P.y / 0.2;
            float2 b = float2(fract(s / 0.4 + 0.5 * floor(row)), fract(row));
            albedo *= 1.0 - 0.07 * max(step(0.96, b.x), step(0.93, b.y)) * near;
        }
        // Rain streaks from the top of the wall, dust splashed up from the ground.
        float storey = in.uv.y;
        albedo *= 1.0 - 0.25 * smoothstep(0.55, 1.0, fbm(float2(s * 2.3, P.y * 0.12), 3));
        albedo = mix(albedo, u.soilA.rgb * 0.9, smoothstep(0.3, -0.05, storey) * 0.55);

        // Far off, windows blur into the wall instead of sparkling.
        float blur = smoothstep(0.12, 0.45, max(fwidth(in.uv.x), fwidth(in.uv.y)));
        float3 wallOnly = albedo;
        if (in.uv.x >= 0.0 && storey > 0.0) {
            float bay = floor(in.uv.x), bx = fract(in.uv.x), level = floor(storey), fy = fract(storey);
            float seed = hash12(float2(bay, dot(base, float3(91.7, 37.3, 53.1))));
            bool shop = mat == 6;
            bool door = level < 0.5 && seed < (shop ? 0.28 : 0.2);
            float2 lo = float2(0.3, 0.32), hi = float2(0.7, 0.72);
            if (door) {
                lo = float2(0.34, 0.0);
                hi = float2(0.66, 0.7);
            } else if (shop && level < 0.5) {
                lo = float2(0.08, 0.12);
                hi = float2(0.92, 0.8);
            } else if (shop) {
                lo = float2(0.14, 0.3);
                hi = float2(0.86, 0.8);
            }
            float2 q = (float2(bx, fy) - lo) / (hi - lo);
            bool opening = all(q > 0.0) && all(q < 1.0) && (door || shop || seed < 0.86);
            if (opening) {
                float2 edge = min(q, 1.0 - q) * (hi - lo);          // distance to the frame, in bay units
                float frame = step(min(edge.x, edge.y * 0.9), 0.022);
                if (door) {
                    const float3 doors[4] = { float3(0.13, 0.07, 0.035), float3(0.05, 0.12, 0.22), float3(0.07, 0.16, 0.10), float3(0.25, 0.24, 0.22) };
                    float3 leaf = doors[int(seed * 80.0) % 4];
                    float2 panel = abs(fract(q * float2(2.0, 3.0)) - 0.5);
                    albedo = leaf * (0.75 + 0.35 * step(max(panel.x, panel.y), 0.36)) * (0.85 + 0.3 * vnoise(float2(s * 40.0, P.y * 6.0)));
                    albedo = mix(albedo, base * 0.55, frame);
                } else {
                    float bars = max(step(abs(q.x - 0.5), shop ? 0.012 : 0.03), step(abs(q.y - 0.62), shop ? 0.0 : 0.03));
                    float3 trim = shop ? float3(0.05, 0.05, 0.055) : float3(0.55, 0.53, 0.48);
                    glass = 1.0 - max(frame, bars);
                    albedo = mix(trim, float3(0.012, 0.016, 0.02), glass);
                    // Curtains and shutters drawn across some of them.
                    float drawn = step(0.6, hash12(float2(bay * 3.1 + level * 7.7, seed * 31.0)));
                    albedo = mix(albedo, base * 0.5 + float3(0.08, 0.07, 0.06), glass * drawn * 0.8);
                    glass *= 1.0 - 0.6 * drawn;
                }
                albedo *= 0.55 + 0.45 * smoothstep(0.0, 0.14, 1.0 - q.y);   // shadow of the lintel
            } else if (!door && all(q > float2(-0.06, -0.1)) && all(q < float2(1.06, 0.0)) && (shop || seed < 0.86)) {
                albedo *= 1.12;                                              // sill
            }
        }
        if (in.uv.x >= 0.0 && storey > 0.0) {
            albedo = mix(albedo, mix(wallOnly, float3(0.03, 0.035, 0.04), mat == 6 ? 0.34 : 0.13), blur);
            glass *= 1.0 - blur;
        }
    } else if (mat == 7) {
        float3 base = in.extra.yzw;
        int cover = int(in.uv.x + 0.5);
        float3 eave = normalize(cross(N, float3(0, 1, 0)) + float3(1e-4, 0, 0));   // level direction along the roof
        float s = dot(P, eave);
        float near = saturate(1.0 - dist / 50.0);
        if (cover == 1) {
            // Corrugated sheet: ribs at 76 mm running down the slope, lapped sheets, rust from the edges and fixings.
            float rib = sin(s * 82.7);
            albedo = base * (0.9 + 0.12 * rib * near);
            N = normalize(N + eave * rib * 0.3 * near);
            albedo *= 0.9 + 0.2 * hash12(floor(float2(s / 0.76, dot(P, cross(eave, N)) / 2.4)));
            float rust = smoothstep(0.5, 0.78, fbm(P.xz * 0.8 + base.xy * 40.0, 4));
            albedo = mix(albedo, float3(0.15, 0.065, 0.03), rust * 0.65);
            gloss = float3(0.22 * (1.0 - rust), 26.0, 0.0);
        } else if (cover == 2) {
            albedo = base * (0.65 + 0.6 * fbm(float2(s * 26.0, P.y * 3.0), 3)) * (0.85 + 0.3 * fract(P.y * 3.3));
        } else if (cover == 3) {
            float row = P.y / 0.11;
            float2 t = float2(fract(s / 0.24 + 0.5 * floor(row)), fract(row));
            albedo = base * (0.75 + 0.3 * t.y) * (0.88 + 0.24 * hash12(floor(float2(s / 0.24 + 0.5 * floor(row), row))));
            albedo *= 1.0 - 0.3 * step(0.94, t.x) * near;
        } else {
            albedo = base * (0.75 + 0.35 * fbm(P.xz * 0.7, 4));
            albedo *= 1.0 - 0.3 * smoothstep(0.6, 0.85, fbm(P.xz * 0.25 + 9.0, 3));
        }
    } else {
        float n = fbm(P.xz * 1.7 + P.y * 1.3, 4);
        albedo = mix(float3(0.10, 0.09, 0.08), float3(0.24, 0.20, 0.16), n);
        albedo = mix(albedo, float3(0.24, 0.25, 0.14), smoothstep(0.62, 0.75, fbm(P.xz * 4.0 + P.y * 2.0, 3)) * 0.6);
    }

    float sh = shadowTerm(P, N, u, smap, cmp);
    float3 col = shade(albedo, N, sh, 1.0, trans, V, u, lut, ls);
    float3 H = normalize(V + u.sunDir.xyz);
    float ndv = saturate(dot(N, V));
    if (gloss.x > 0.0) col += u.sunColor.rgb * 0.3183 * sh * gloss.x * pow(saturate(dot(N, H)), gloss.y) * saturate(dot(N, u.sunDir.xyz));
    if (glass > 0.0) {
        // Window glass mirrors the sky, more at a glancing angle, and flashes when it catches the sun.
        float3 R = reflect(-V, N);
        float fres = 0.05 + 0.95 * pow(1.0 - ndv, 5.0);
        col += glass * fres * skyLookup(lut, ls, normalize(float3(R.x, abs(R.y) + 0.02, R.z)));
        col += glass * u.sunColor.rgb * sh * pow(saturate(dot(R, u.sunDir.xyz)), 300.0) * 0.6;
    }
    return float4(applyFog(col, P, u, lut, ls), alpha);
}

// ---------------------------------------------------------------- people

struct SkinIn {
    float3 position [[attribute(0)]];
    float3 normal [[attribute(1)]];
    float2 uv [[attribute(2)]];
    float4 joints [[attribute(3)]];
    float4 weights [[attribute(4)]];
    float4 extra [[attribute(5)]];   // colour slice, normal slice (-1 none), skin may show here, cut out by alpha
};

struct SkinV {
    float4 position [[position]];
    float3 wpos;
    float3 normal;
    float2 uv;
    float4 extra;
    float tone [[flat]];
    float seed [[flat]];
};

// Adds one frame of the pose table, weighted. Each joint is three rows of a 3x4 matrix; 80 joints to a frame.
static void addPose(const device float4 *pal, float frame, float weight, SkinIn in, float3 &p, float3 &n) {
    if (weight < 0.004) return;
    int base = int(frame) * 80;
    float4 v = float4(in.position, 1.0);
    for (int k = 0; k < 4; k++) {
        float w = in.weights[k] * weight;
        if (w <= 0.0) continue;
        int o = (base + int(in.joints[k] + 0.5)) * 3;
        float4 r0 = pal[o], r1 = pal[o + 1], r2 = pal[o + 2];
        p += w * float3(dot(r0, v), dot(r1, v), dot(r2, v));
        n += w * float3(dot(r0.xyz, in.normal), dot(r1.xyz, in.normal), dot(r2.xyz, in.normal));
    }
}

static float3 skinnedPos(SkinIn in, Inst I, const device float4 *pal, float3 &n) {
    float3 p = float3(0.0);
    n = float3(0.0);
    float fa = floor(I.c.x), fb = floor(I.c.y), ta = I.c.x - fa, tb = I.c.y - fb, blend = I.c.z;
    addPose(pal, fa, (1.0 - ta) * (1.0 - blend), in, p, n);
    addPose(pal, fa + 1.0, ta * (1.0 - blend), in, p, n);
    addPose(pal, fb, (1.0 - tb) * blend, in, p, n);
    addPose(pal, fb + 1.0, tb * blend, in, p, n);
    // The head turns about its joint to look at someone; the neck follows part-way.
    float turn = I.d.w * fract(in.extra.z) / 0.49;
    if (abs(turn) > 0.001) {
        float c = cos(turn), s = sin(turn);
        float3 q = p - I.d.xyz;
        p = I.d.xyz + float3(c * q.x + s * q.z, q.y, -s * q.x + c * q.z);
        n = float3(c * n.x + s * n.z, n.y, -s * n.x + c * n.z);
    }
    n = normalize(n);
    float3 lp = p * I.a.w;
    n = float3(I.b.x * n.x + I.b.y * n.z, n.y, -I.b.y * n.x + I.b.x * n.z);
    return float3(I.b.x * lp.x + I.b.y * lp.z, lp.y, -I.b.y * lp.x + I.b.x * lp.z) + I.a.xyz;
}

vertex SkinV skin_vs(SkinIn in [[stage_in]], uint iid [[instance_id]], constant U &u [[buffer(1)]],
                     const device Inst *inst [[buffer(2)]], const device float4 *pal [[buffer(3)]]) {
    Inst I = inst[iid];
    SkinV o;
    float3 n;
    o.wpos = skinnedPos(in, I, pal, n);
    o.position = u.viewProj * float4(o.wpos, 1.0);
    o.normal = n;
    o.uv = in.uv;
    o.extra = float4(in.extra.xy, floor(in.extra.z), in.extra.w);
    o.tone = I.c.w;
    o.seed = I.b.z;
    return o;
}

struct SkinShadowV {
    float4 position [[position]];
    float2 uv;
    float2 sliceAlpha;
};

vertex SkinShadowV skin_shadow_vs(SkinIn in [[stage_in]], uint iid [[instance_id]], constant U &u [[buffer(1)]],
                                  const device Inst *inst [[buffer(2)]], const device float4 *pal [[buffer(3)]]) {
    SkinShadowV o;
    float3 n;
    o.position = u.viewProj * float4(skinnedPos(in, inst[iid], pal, n), 1.0);
    o.position.z = max(o.position.z, 0.0001);
    o.uv = in.uv;
    o.sliceAlpha = in.extra.xw;
    return o;
}

fragment void skin_shadow_fs(SkinShadowV in [[stage_in]], texture2d_array<float> colour [[texture(6)]], sampler ts [[sampler(3)]]) {
    if (in.sliceAlpha.y > 0.5 && colour.sample(ts, in.uv, uint(in.sliceAlpha.x + 0.5)).a < 0.4) discard_fragment();
}

// Woven and printed cloth for the garments cut in Garments.swift; uv is in metres along the weave.
static float3 clothColour(int kind, float seed, float2 uv) {
    float3 c;
    if (kind == 1) {
        // Shuka: red, sometimes blue or purple, crossed by dark and pale lines.
        float pick = hash12(float2(seed * 53.0, 4.1));
        float3 ground = pick < 0.68 ? float3(0.52, 0.035, 0.03) : (pick < 0.86 ? float3(0.05, 0.09, 0.42) : float3(0.30, 0.04, 0.34));
        float2 g = abs(fract(uv / 0.11) - 0.5);
        float2 wide = smoothstep(0.38, 0.40, g), thin = smoothstep(0.455, 0.47, abs(fract(uv / 0.11 + 0.25) - 0.5));
        c = mix(ground, float3(0.03, 0.03, 0.07), max(wide.x, wide.y) * 0.85);
        c = mix(c, float3(0.75, 0.72, 0.6), max(thin.x, thin.y) * 0.3);
    } else if (kind == 2) {
        // Wax print: a deep ground, a second dye and a pale resist, in a small repeating motif.
        int set = int(hash12(float2(seed * 71.0, 2.7)) * 6.0);
        float3 a = float3(0.03, 0.06, 0.22), b = float3(0.62, 0.33, 0.04);
        if (set == 1) { a = float3(0.32, 0.03, 0.04); b = float3(0.72, 0.50, 0.08); }
        if (set == 2) { a = float3(0.03, 0.17, 0.10); b = float3(0.60, 0.42, 0.05); }
        if (set == 3) { a = float3(0.40, 0.17, 0.03); b = float3(0.05, 0.09, 0.26); }
        if (set == 4) { a = float3(0.05, 0.20, 0.30); b = float3(0.55, 0.10, 0.06); }
        if (set == 5) { a = float3(0.22, 0.04, 0.18); b = float3(0.66, 0.45, 0.10); }
        float3 pale = float3(0.78, 0.71, 0.52);
        float2 q = uv / 0.085;
        q.x += 0.5 * floor(q.y);
        float2 cell = fract(q) - 0.5;
        float d = length(cell), petals = cos(atan2(cell.y, cell.x) * (4.0 + floor(hash12(float2(seed * 13.0, 9.0)) * 4.0)));
        c = mix(a, b, smoothstep(0.38 + 0.08 * petals, 0.34 + 0.08 * petals, d));
        c = mix(c, pale, smoothstep(0.15, 0.13, d) * 0.9);
        c = mix(c, a, smoothstep(0.06, 0.05, d));
        // Fine veins where the wax cracked and the dye crept in.
        c = mix(c, a * 0.7, smoothstep(0.62, 0.7, vnoise(uv * 160.0)) * 0.35);
    } else {
        c = float3(0.80, 0.79, 0.74) * (0.94 + 0.06 * vnoise(uv * float2(900.0, 140.0)));
    }
    return c;
}

// How much a texel looks like skin, from its share of red and green: skin of any depth keeps much the same hue.
static float skinLike(float3 c) {
    float3 g = sqrt(max(c, 0.0));
    float sum = g.r + g.g + g.b + 1e-4;
    float r = g.r / sum, gr = g.g / sum;
    return smoothstep(0.365, 0.395, r) * (1.0 - smoothstep(0.50, 0.56, r)) * smoothstep(0.27, 0.295, gr) * (1.0 - smoothstep(0.345, 0.365, gr));
}

fragment float4 skin_fs(SkinV in [[stage_in]], constant U &u [[buffer(1)]],
                        texture2d<float> lut [[texture(0)]], depth2d_array<float> smap [[texture(1)]],
                        texture2d_array<float> colour [[texture(6)]], texture2d_array<float> normals [[texture(7)]],
                        sampler ls [[sampler(0)]], sampler cmp [[sampler(1)]], sampler ts [[sampler(3)]]) {
    float3 P = in.wpos;
    float3 V = normalize(u.camPos.xyz - P);
    if (in.extra.x < -0.5) {
        // Cloth: lit from both sides, with soft folds running down it.
        float3 Nc = normalize(in.normal);
        if (dot(Nc, V) < 0.0) Nc = -Nc;
        float fold = sin(in.uv.x * 46.0 + 3.0 * vnoise(in.uv * float2(9.0, 2.5) + in.seed * 30.0));
        float3 Tc = normalize(cross(float3(0.0, 1.0, 0.0), Nc) + 1e-4);
        Nc = normalize(Nc + Tc * fold * 0.22);
        float3 cloth = clothColour(int(-in.extra.x + 0.5), in.seed, in.uv) * (0.9 + 0.1 * fold);
        float shc = shadowTerm(P, Nc, u, smap, cmp);
        return float4(applyFog(shade(cloth, Nc, shc, 1.0, 0.25, V, u, lut, ls), P, u, lut, ls), 1.0);
    }
    float4 tex = colour.sample(ts, in.uv, uint(in.extra.x + 0.5));
    float alpha = 1.0;
    if (in.extra.w > 0.5) {
        alpha = tex.a;
        if (alpha < 0.08) discard_fragment();
    }
    float3 N = normalize(in.normal);
    if (in.extra.y > -0.5) {
        // Folds and creases from the normal map, in a frame built from how position and uv change across the pixel.
        float3 m = normals.sample(ts, in.uv, uint(in.extra.y + 0.5)).xyz * 2.0 - 1.0;
        float3 dp1 = dfdx(P), dp2 = dfdy(P);
        float2 d1 = dfdx(in.uv), d2 = dfdy(in.uv);
        float3 dp2p = cross(dp2, N), dp1p = cross(N, dp1);
        float3 T = dp2p * d1.x + dp1p * d2.x, B = dp2p * d1.y + dp1p * d2.y;
        float scale = rsqrt(max(max(dot(T, T), dot(B, B)), 1e-20));
        N = normalize(T * scale * m.x + B * scale * m.y + N * max(m.z, 0.2));
    }
    float3 albedo = tex.rgb;
    float like = skinLike(albedo);
    float skin = like * saturate(in.extra.z);
    // The same figure turns up in different colours: half of them have the dye of their clothes turned round the colour wheel.
    float dye = hash12(float2(in.seed * 91.0, 7.3));
    if (dye > 0.5 && in.extra.z < 1.5 && like < 0.5) {
        float a = (hash12(float2(in.seed * 37.0, 1.9)) - 0.5) * 6.2832, ca = cos(a), sa = sin(a);
        float3 yiq = float3(dot(albedo, float3(0.299, 0.587, 0.114)), dot(albedo, float3(0.596, -0.274, -0.322)), dot(albedo, float3(0.211, -0.523, 0.312)));
        yiq.yz = float2(yiq.y * ca - yiq.z * sa, yiq.y * sa + yiq.z * ca);
        albedo = max(float3(dot(yiq, float3(1.0, 0.956, 0.621)), dot(yiq, float3(1.0, -0.272, -0.647)), dot(yiq, float3(1.0, -1.106, 1.703))), 0.0);
    }
    // Darker skin returns less light and a little less of the green and blue.
    float3 depth = in.tone * mix(float3(1.0), float3(1.0, 0.88, 0.78), saturate(1.0 - in.tone));
    // Hair, brows and lashes darken with the skin: whatever on the head is warm in hue but is not skin.
    float3 g = sqrt(max(albedo, 1e-5));
    float hair = saturate(in.extra.z - 1.0) * (1.0 - skin) * smoothstep(1.05, 1.14, g.r / g.b);
    albedo *= mix(float3(1.0), depth, skin) * mix(1.0, min(in.tone * in.tone, 1.0), hair);

    float sh = shadowTerm(P, N, u, smap, cmp);
    float3 col = shade(albedo, N, sh, 1.0, 0.0, V, u, lut, ls);
    float3 H = normalize(V + u.sunDir.xyz);
    float ndl = saturate(dot(N, u.sunDir.xyz));
    // A soft sheen on skin, a duller one on cloth, and light catching the edge of the figure against the sky.
    float sheen = mix(0.035, 0.10, skin);
    col += u.sunColor.rgb * 0.3183 * sh * ndl * sheen * pow(saturate(dot(N, H)), mix(12.0, 28.0, skin));
    col += skyAmbient(lut, ls) * albedo * 0.5 * pow(1.0 - saturate(dot(N, V)), 4.0);
    return float4(applyFog(col, P, u, lut, ls), alpha);
}

// ---------------------------------------------------------------- grass

struct GrassInst {
    float4 a;   // xyz root, w height scale (0 = culled)
    float4 b;   // cos, sin, seed, green
    float4 c;   // terrain normal xyz, shadow
};

struct GrassGrid {
    float4 a;   // origin cell x, origin cell z, cell size, N
    float4 b;   // fade in start, fade in end, fade out start, fade out end
};

kernel void grass_place(uint2 gid [[thread_position_in_grid]],
                        constant U &u [[buffer(0)]], device GrassInst *out [[buffer(1)]],
                        constant GrassGrid &grid [[buffer(2)]],
                        texture2d<float> hmap [[texture(0)]], depth2d_array<float> smap [[texture(1)]],
                        texture2d<float> nearSat [[texture(2)]], texture2d<float> mapMask [[texture(3)]],
                        sampler ls [[sampler(0)]], sampler cmp [[sampler(1)]]) {
    uint N = uint(grid.a.w);
    if (gid.x >= N || gid.y >= N) return;

    float2 cid = grid.a.xy + float2(gid);
    float2 hid = cid + grid.a.z * 517.0;
    float h1 = hash12(hid), h2 = hash12(hid + 37.7), h3 = hash12(hid + 71.3), h4 = hash12(hid + 113.1);
    float2 xz = (cid + float2(h1, h2)) * grid.a.z;
    float ext = u.world.x;

    GrassInst g;
    g.a = float4(0);
    g.b = float4(1, 0, 0, 0);
    g.c = float4(0, 1, 0, 1);

    float camDist = distance(xz, u.camPos.xz);
    float fade = smoothstep(grid.b.x, grid.b.y, camDist) * (1.0 - smoothstep(grid.b.z, grid.b.w, camDist));
    if (fade > 0.01 && all(abs(xz) < ext - 2.0)) {
        float cover = grassCover(xz, u.biome.x) * (1.0 - pathMask(xz));
        if (u.real.x > 0.5) {
            float4 mapped = mapMask.sample(ls, (xz + 1024.0) / 2048.0, level(0));
            cover = grassCover(xz, u.biome.x) * satVeg(nearSat.sample(ls, (xz + 1024.0) / 2048.0, level(0)).rgb * 0.9, u.real.z)
                  * (1.0 - saturate((mapped.r + mapped.g + mapped.b + mapped.a) * 3.0));
        }
        if (cover > 0.08) {
            float W = float(hmap.get_width());
            float sp = 2.0 * ext / (W - 1.0);
            float2 uv = ((xz + ext) / sp + 0.5) / W;
            float tx = 1.0 / W;
            float y = hmap.sample(ls, uv, level(0)).r;
            float hx = hmap.sample(ls, uv + float2(tx, 0), level(0)).r - hmap.sample(ls, uv - float2(tx, 0), level(0)).r;
            float hz = hmap.sample(ls, uv + float2(0, tx), level(0)).r - hmap.sample(ls, uv - float2(0, tx), level(0)).r;
            float3 n = normalize(float3(-hx, 2.0 * sp, -hz));
            float3 P = float3(xz.x, y, xz.y);

            bool visible = n.y > 0.86 && (u.real.x < 0.5 || y > u.real.y + 0.4);
            for (int i = 0; i < 4; i++) {
                if (dot(u.frustum[i].xyz, P) + u.frustum[i].w < -1.6) visible = false;
            }
            if (visible) {
                float tall = 0.7 + 0.6 * fbm(xz * 0.07 + 3.1, 2);
                float ang = h4 * 6.2831853;
                g.a = float4(P, (0.5 + 0.6 * h3) * tall * fade * smoothstep(0.08, 0.5, cover) * u.biome.y);
                g.b = float4(cos(ang), sin(ang), h3, smoothstep(0.50, 0.68, moisture(xz) + u.biome.z));
                g.c = float4(n, shadowTerm(P + float3(0, 0.35, 0), float3(0, 1, 0), u, smap, cmp));
            }
        }
    }
    out[gid.y * N + gid.x] = g;
}

struct GrassV {
    float4 position [[position]];
    float3 wpos;
    float3 normal;
    float t;
    float4 params [[flat]];   // seed, green, shadow, blade random
    float3 groundN [[flat]];
};

vertex GrassV grass_vs(MeshIn in [[stage_in]], uint iid [[instance_id]],
                       constant U &u [[buffer(1)]], const device GrassInst *inst [[buffer(2)]]) {
    GrassInst g = inst[iid];
    GrassV o;
    o.t = in.uv.y;
    o.params = float4(g.b.z, g.b.w, g.c.w, in.extra.x);
    o.groundN = g.c.xyz;
    float s = g.a.w;
    if (s <= 0.0) {
        o.position = float4(0, 0, -1, 1);
        o.wpos = float3(0);
        o.normal = float3(0, 1, 0);
        return o;
    }

    // Blades widen with distance so the field keeps its cover and does not shimmer.
    float3 lp = in.position;
    lp.xz += in.extra.yz * min(distance(g.a.xyz, u.camPos.xyz) * 0.07, 4.0);
    lp.y *= s;
    float3 wp = float3(g.b.x * lp.x + g.b.y * lp.z, lp.y, -g.b.y * lp.x + g.b.x * lp.z) + g.a.xyz;

    float tm = u.camPos.w;
    float2 wdir = normalize(float2(1.0, 0.35));
    float gust = vnoise(wp.xz * 0.05 - wdir * tm * 0.6);
    float bend = (0.05 + 0.2 * gust) * sin(tm * 2.2 + dot(wp.xz, float2(0.9, 0.7)) + g.b.z * 6.28) + 0.2 * gust;
    wp.xz += wdir * bend * o.t * o.t * s;

    float3 n = in.normal;
    o.normal = float3(g.b.x * n.x + g.b.y * n.z, n.y, -g.b.y * n.x + g.b.x * n.z);
    o.wpos = wp;
    o.position = u.viewProj * float4(wp, 1.0);
    return o;
}

fragment float4 grass_fs(GrassV in [[stage_in]], bool front [[front_facing]], constant U &u [[buffer(1)]],
                         texture2d<float> lut [[texture(0)]], texture2d<float> nearSat [[texture(2)]],
                         sampler ls [[sampler(0)]], sampler cs [[sampler(2)]]) {
    float3 P = in.wpos;
    float3 V = normalize(u.camPos.xyz - P);
    float green = in.params.y;
    float r = in.params.w;
    float3 base = mix(u.grassDry.rgb * 0.32, float3(0.05, 0.075, 0.022), green);
    float3 dry = u.grassDry.rgb * mix(float3(1.0), float3(0.75, 0.62, 0.62), smoothstep(0.55, 1.0, r));
    float3 tip = mix(dry, float3(0.13, 0.17, 0.05), green * (0.4 + 0.6 * r));
    if (u.real.x > 0.5) {
        float3 sat = nearSat.sample(cs, (P.xz + 1024.0) / 2048.0).rgb * 0.9;
        tip = mix(tip, sat * 1.5, 0.75) * (0.8 + 0.4 * r);
        base = tip * 0.4;
    }
    float3 albedo = mix(base, tip, smoothstep(0.0, 0.85, in.t)) * (0.8 + 0.3 * in.params.x);

    float3 bladeN = normalize(in.normal) * (front ? 1.0 : -1.0);
    float3 N = normalize(mix(in.groundN, bladeN, 0.35));
    // Lower parts of a blade are shaded by the blades around it.
    float depth = pow(in.t, 0.8);
    float3 col = shade(albedo, N, in.params.z * mix(0.3, 1.0, depth), mix(0.3, 1.0, depth), 0.45 * in.t, V, u, lut, ls);
    return float4(applyFog(col, P, u, lut, ls), 1.0);
}

// ---------------------------------------------------------------- sea

struct WaterV {
    float4 position [[position]];
    float3 wpos;
};

vertex WaterV water_vs(uint vid [[vertex_id]], constant U &u [[buffer(1)]]) {
    const float2 corners[6] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(-1, 1), float2(1, -1), float2(1, 1) };
    WaterV o;
    o.wpos = float3(u.camPos.x + corners[vid].x * 170000.0, u.real.y, u.camPos.z + corners[vid].y * 170000.0);
    o.position = u.viewProj * float4(o.wpos, 1.0);
    return o;
}

static float swell(float2 xz, float t, float fine) {
    return fbm(xz * 0.08 + t * float2(0.25, 0.1), 3) + fbm(xz * 0.23 - t * float2(0.1, 0.3), 3) * 0.4
         + vnoise(xz * 0.9 + t * float2(0.5, -0.4)) * 0.1 * fine;
}

fragment float4 water_fs(WaterV in [[stage_in]], constant U &u [[buffer(1)]],
                         texture2d<float> lut [[texture(0)]], depth2d_array<float> smap [[texture(1)]],
                         texture2d<float> hmap [[texture(4)]],
                         sampler ls [[sampler(0)]], sampler cmp [[sampler(1)]], sampler cs [[sampler(2)]]) {
    float3 P = in.wpos;
    float2 xz = P.xz;
    float3 toCam = u.camPos.xyz - P;
    float dist = length(toCam);
    float3 V = toCam / dist;
    float t = u.camPos.w;
    float3 L = u.sunDir.xyz;

    float fine = saturate(1.0 - dist / 120.0);
    float e = 0.4 + dist * 0.01;
    float s0 = swell(xz, t, fine);
    float3 N = normalize(float3((s0 - swell(xz + float2(e, 0), t, fine)) / e, 1.0, (s0 - swell(xz + float2(0, e), t, fine)) / e) * float3(1.4, 1.0, 1.4));
    N = normalize(mix(N, float3(0, 1, 0), saturate(dist / 2500.0)));

    // Depth to the seabed where the height field knows it; open sea beyond.
    float ext = u.world.x;
    float depth = 8.0;
    if (all(abs(xz) < ext)) {
        float W = float(hmap.get_width());
        depth = max(u.real.y - hmap.sample(cs, ((xz + ext) / (2.0 * ext / (W - 1.0)) + 0.5) / W).r, 0.0);
        depth = mix(depth, 8.0, smoothstep(ext - 150.0, ext, max(abs(xz.x), abs(xz.y))));
    }

    float3 sunE = u.sunColor.rgb * 0.3183;
    float3 skyA = skyAmbient(lut, ls);
    float3 light = sunE * saturate(L.y) + skyA;
    float3 body = mix(float3(0.09, 0.26, 0.24), float3(0.008, 0.045, 0.07), 1.0 - exp(-depth * 0.35)) * light;
    float3 bed = float3(0.20, 0.18, 0.13) * light;
    float3 col = mix(bed, body, 1.0 - exp(-depth * 1.2));

    float fres = 0.02 + 0.98 * pow(1.0 - saturate(dot(N, V)), 5.0);
    float3 R = reflect(-V, N);
    R.y = abs(R.y);
    float sh = shadowTerm(P, float3(0, 1, 0), u, smap, cmp);
    float3 refl = skyLookup(lut, ls, normalize(R)) + u.sunColor.rgb * pow(saturate(dot(R, L)), 500.0) * 6.0 * sh;
    col = col * (1.0 - fres) + refl * fres;

    // Surf: a band that breathes in and out along the shore, and broken water over shallows.
    float wash = 0.5 + 0.5 * sin(t * 0.7 + fbm(xz * 0.05, 2) * 12.0);
    float foam = smoothstep(0.4 + 0.8 * wash, 0.0, depth) * smoothstep(0.35, 0.6, fbm(xz * 0.7 + t * float2(0.2, 0.1), 3));
    foam += (1.0 - smoothstep(0.3, 1.6, depth)) * smoothstep(0.60, 0.70, fbm(xz * 0.12 - t * float2(0.05, 0.12), 3)) * 0.7;
    foam *= saturate(1.5 - dist / 600.0);   // distant foam only shimmers
    col = mix(col, float3(0.85) * light, saturate(foam));
    return float4(applyFog(col, P, u, lut, ls), 1.0);
}
