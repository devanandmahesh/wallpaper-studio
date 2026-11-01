/// Metal Shading Language source. The Command Line Tools have no offline `metal` compiler, so the library is
/// compiled from this string at launch (`MTLDevice.makeLibrary(source:)`), once per process.
///
/// Design: one vertex shader and one "uber" fragment shader draw every layer. A layer is a quad whose corners are
/// computed from `LayerUniforms` (no vertex buffers), so a frame needs no allocations: uniforms go through
/// `setVertexBytes` / `setFragmentBytes`. Colours are handled in sRGB-encoded space (render target and textures are
/// both non-sRGB `bgra8Unorm`), which keeps the output identical to the Core Animation renderers.
enum Shaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct LayerUniforms {
        float4 color;
        float4 color2;
        float4 lightColor;
        float2 axis0;
        float2 axis1;
        float2 translate;
        float2 light;
        float2 depthShift;
        float2 canvas;
        float  opacity;
        int    kind;
        float  time;
        float  speed;
        float  scale;
        float  hueShift;
        float  brightness;
        float  contrast;
        float  saturation;
        float  vignette;
        float  vignetteRadius;
        float  rippleAmp;
        float  rippleFreq;
        float  rippleSpeed;
        float  lightRadius;
        float  lightIntensity;
        float  lightFlicker;
        int    hasDepth;
        float  vizBars;
        float  vizThickness;
        float  vizGap;
        float  vizGlow;
        float  vizMirror;
        float  vizSize;
    };

    struct VOut {
        float4 position [[position]];
        float2 uv;
        float2 screen;
    };

    vertex VOut layerVertex(uint vid [[vertex_id]], constant LayerUniforms &u [[buffer(0)]]) {
        const float2 corners[4] = { float2(-0.5, -0.5), float2(0.5, -0.5), float2(-0.5, 0.5), float2(0.5, 0.5) };
        float2 l = corners[vid];
        float2 p = u.axis0 * l.x + u.axis1 * l.y + u.translate;
        VOut o;
        o.position = float4(p, 0.0, 1.0);
        o.uv = float2(l.x + 0.5, 0.5 - l.y);
        o.screen = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
        return o;
    }

    constant float3x3 toYIQ   = float3x3(float3(0.299, 0.596, 0.211), float3(0.587, -0.274, -0.523), float3(0.114, -0.322, 0.312));
    constant float3x3 fromYIQ = float3x3(float3(1.0, 1.0, 1.0), float3(0.956, -0.272, -1.106), float3(0.621, -0.647, 1.703));

    float3 hueRotate(float3 c, float angle) {
        float3 yiq = toYIQ * c;
        float s = sin(angle), co = cos(angle);
        yiq = float3(yiq.x, yiq.y * co - yiq.z * s, yiq.y * s + yiq.z * co);
        return fromYIQ * yiq;
    }

    float4 plasma(float2 uv, constant LayerUniforms &u) {
        float t = u.time * u.speed;
        float2 p = (uv - 0.5) * 6.0 * u.scale;
        float v = sin(p.x + t) + sin(p.y * 1.3 + t * 1.1) + sin((p.x + p.y) * 0.8 + t * 0.7)
                + sin(length(p) * 1.5 - t * 1.3);
        float m = 0.5 + 0.5 * sin(v * 1.2);
        return float4(mix(u.color.rgb, u.color2.rgb, m), 1.0);
    }

    float4 aurora(float2 uv, constant LayerUniforms &u) {
        float t = u.time * u.speed;
        float wave = sin(uv.x * 5.0 * u.scale + t + sin(uv.x * 2.3 * u.scale - t * 0.6) * 1.8);
        float centre = 0.38 + 0.10 * wave + 0.04 * sin(uv.x * 11.0 + t * 1.7);
        float d = (uv.y - centre) * 4.5;
        float band = exp(-d * d) * (0.55 + 0.45 * sin(uv.x * 17.0 * u.scale - t * 2.0));
        float3 col = mix(u.color.rgb, u.color2.rgb, clamp(uv.x + 0.25 * wave, 0.0, 1.0));
        return float4(col * band, clamp(band, 0.0, 1.0));
    }

    float4 waves(float2 uv, constant LayerUniforms &u) {
        float t = u.time * u.speed;
        float y = 0.62 + 0.035 * sin(uv.x * 9.0 * u.scale + t) + 0.02 * sin(uv.x * 23.0 * u.scale - t * 1.4);
        float body = smoothstep(y - 0.004, y + 0.004, uv.y);
        float crest = exp(-pow((uv.y - y) * 90.0, 2.0));
        float3 water = mix(u.color.rgb, u.color2.rgb, clamp((uv.y - y) * 2.5, 0.0, 1.0));
        return float4(water + crest * 0.35, body);
    }

    // ---------------------------------------------------------------- audio visualisers
    // `audio` is AudioFrame.packed: 32 bands, 64 waveform samples, then bass, mid, treble, level, beat.

    float barValue(constant float *audio, int idx, int n) {
        int per = max(32 / n, 1);
        float v = 0.0;
        for (int k = 0; k < per; k++) v = max(v, audio[min(idx * per + k, 31)]);
        return v;
    }

    float slotMask(float local, float gap) {
        float margin = gap * 0.5;
        return smoothstep(margin - 0.02, margin + 0.0001, local) * (1.0 - smoothstep(1.0 - margin - 0.0001, 1.0 - margin + 0.02, local));
    }

    float4 vizBars(float2 uv, constant LayerUniforms &u, constant float *audio) {
        int n = int(u.vizBars);
        bool mirror = u.vizMirror > 0.5;
        float xm = mirror ? abs(uv.x * 2.0 - 1.0) : uv.x;
        float pos = xm * float(n);
        int idx = min(int(pos), n - 1);
        float v = barValue(audio, idx, n);
        float yb = mirror ? abs(uv.y - 0.5) : (1.0 - uv.y);
        float h = max(v * u.scale, 0.004);
        float mask = slotMask(fract(pos), u.vizGap);
        float body = (1.0 - smoothstep(h - 0.003, h, yb)) * mask;
        float halo = u.vizGlow * v * exp(-max(yb - h, 0.0) * 18.0) * mask * 0.6;
        float3 col = mix(u.color.rgb, u.color2.rgb, float(idx) / float(max(n - 1, 1)));
        return float4(col * (1.0 + 0.5 * v), clamp(body + halo, 0.0, 1.0));
    }

    float4 vizCircular(float2 uv, constant LayerUniforms &u, constant float *audio) {
        float aspect = u.canvas.x / max(u.canvas.y, 1.0);
        float2 p = (uv - 0.5) * float2(aspect, 1.0);
        float r = length(p);
        float turns = atan2(p.y, p.x) / 6.2831853 + u.time * u.speed;
        float t = abs(fract(turns) * 2.0 - 1.0);
        int n = int(u.vizBars);
        float pos = t * float(n);
        int idx = min(int(pos), n - 1);
        float v = barValue(audio, idx, n);
        float base = u.vizSize + audio[96] * 0.02;
        float h = max(v * u.scale, 0.003);
        float mask = slotMask(fract(pos), u.vizGap);
        float radial = smoothstep(base - 0.002, base, r) * (1.0 - smoothstep(base + h, base + h + 0.003, r));
        float ring = exp(-pow((r - base) / max(u.vizThickness, 0.0005), 2.0));
        float halo = u.vizGlow * v * exp(-max(r - (base + h), 0.0) * 16.0) * mask * 0.5;
        float3 col = mix(u.color.rgb, u.color2.rgb, t);
        return float4(col * (1.0 + 0.5 * v), clamp(radial * mask + ring * 0.6 + halo, 0.0, 1.0));
    }

    float4 vizWave(float2 uv, constant LayerUniforms &u, constant float *audio) {
        float x = uv.x * 63.0;
        int i = min(int(x), 62);
        float w = mix(audio[32 + i], audio[33 + i], x - float(i));
        float y = 0.5 - w * u.scale * 0.5;
        float d = abs(uv.y - y);
        float line = exp(-pow(d / max(u.vizThickness, 0.0005), 2.0));
        float halo = u.vizGlow * exp(-d * 14.0) * (0.15 + audio[99]) * 0.5;
        float3 col = mix(u.color.rgb, u.color2.rgb, uv.x);
        return float4(col * (1.0 + 0.4 * audio[99]), clamp(line + halo, 0.0, 1.0));
    }

    fragment float4 layerFragment(VOut in [[stage_in]],
                                  constant LayerUniforms &u [[buffer(0)]],
                                  constant float *audio [[buffer(1)]],
                                  texture2d<float> tex [[texture(0)]],
                                  texture2d<float> depth [[texture(1)]]) {
        constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
        float2 uv = in.uv;
        float4 c;
        switch (u.kind) {
        case 1:  c = u.color; break;
        case 2:  c = float4(mix(u.color.rgb, u.color2.rgb, uv.y), mix(u.color.a, u.color2.a, uv.y)); break;
        case 3:  c = plasma(uv, u); break;
        case 4:  c = aurora(uv, u); break;
        case 5:  c = waves(uv, u); break;
        case 6:  c = vizBars(uv, u, audio); break;
        case 7:  c = vizCircular(uv, u, audio); break;
        case 8:  c = vizWave(uv, u, audio); break;
        default: {
            if (u.rippleAmp != 0.0) {
                float t = u.time * u.rippleSpeed;
                uv += u.rippleAmp * float2(sin(u.rippleFreq * uv.y + t), cos(u.rippleFreq * uv.x + t));
            }
            if (u.hasDepth != 0) {
                float d = depth.sample(linearClamp, in.uv).r;
                uv += float2(-u.depthShift.x * 0.5, u.depthShift.y * 0.5) * d;
            }
            c = tex.sample(linearClamp, uv);
            if (c.a > 0.0) c.rgb /= c.a;          // textures are stored premultiplied; the colour maths below wants straight colour
            break;
        }
        }

        float3 rgb = c.rgb;
        float a = c.a;

        // Colour effects (straight colour).
        if (u.hueShift != 0.0) rgb = hueRotate(rgb, -u.hueShift);   // YIQ turns the other way round from HSV hue
        float luma = dot(rgb, float3(0.299, 0.587, 0.114));
        rgb = mix(float3(luma), rgb, u.saturation);
        rgb = (rgb - 0.5) * u.contrast + 0.5 + u.brightness;
        rgb = clamp(rgb, 0.0, 1.0);

        float3 p = rgb * a;                       // premultiplied from here on

        // Vignette: black laid over the layer, so a transparent layer becomes a pure dark overlay.
        if (u.vignette > 0.0) {
            float aspect = u.canvas.x / max(u.canvas.y, 1.0);
            float dist = length((in.screen - 0.5) * float2(aspect, 1.0)) / (0.5 * sqrt(aspect * aspect + 1.0));
            float m = u.vignette * smoothstep(u.vignetteRadius * 0.55, 1.05, dist);
            p *= (1.0 - m);
            a = a + (1.0 - a) * m;
        }

        // Animated light: additive glow.
        if (u.lightIntensity > 0.0) {
            float aspect = u.canvas.x / max(u.canvas.y, 1.0);
            float d = length((in.screen - u.light) * float2(aspect, 1.0));
            float f = pow(max(1.0 - d / max(u.lightRadius, 0.001), 0.0), 2.0);
            float wobble = 1.0 + u.lightFlicker * 0.5 * (sin(u.time * 13.0) * 0.5 + sin(u.time * 7.3 + 1.7) * 0.5);
            p += u.lightColor.rgb * (f * u.lightIntensity * wobble);
        }

        return float4(p, a) * u.opacity;
    }

    // ---------------------------------------------------------------- particles

    struct Particle {
        float2 position;
        float2 velocity;
        float  age;
        float  life;
        float  size;
        uint   generation;
    };

    struct ParticleParams {
        float4 colorStart;
        float4 colorEnd;
        float2 emitterCenter;
        float2 emitterHalf;
        float2 gravity;
        float2 pointer;
        float2 burstPosition;
        float2 canvas;
        float  dt;
        float  time;
        float  lifeMin;
        float  lifeMax;
        float  speedMin;
        float  speedMax;
        float  direction;
        float  spread;
        float  drag;
        float  turbulence;
        float  sizeStart;
        float  sizeEnd;
        float  sizeJitter;
        float  pointerStrength;
        float  pointerRadius;
        float  burstSpeed;
        float  simAspect;
        float  keyBoost;
        float  opacity;
        uint   count;
        uint   seed;
        uint   shape;
        uint   pointerMode;
        uint   pointerActive;
        uint   burstStart;
        uint   burstCount;
        uint   initialize;
        uint   prewarm;
    };

    // Integer hash shared bit-for-bit with the CPU reference (ParticleReference.swift).
    uint pcg(uint v) {
        uint state = v * 747796405u + 2891336453u;
        uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
        return (word >> 22u) ^ word;
    }

    float prand(uint id, uint gen, uint seed, uint k) {
        uint h = pcg(seed + pcg(id + pcg(gen * 16u + k)));
        return float(h >> 8u) * (1.0 / 16777216.0);
    }

    void spawnParticle(thread Particle &p, uint id, constant ParticleParams &P) {
        uint gen = p.generation;
        p.life = mix(P.lifeMin, P.lifeMax, prand(id, gen, P.seed, 0u));
        if (P.shape == 0u) {
            p.position = P.emitterCenter;
        } else if (P.shape == 1u) {
            p.position = P.emitterCenter + float2(prand(id, gen, P.seed, 1u) * 2.0 - 1.0, prand(id, gen, P.seed, 2u) * 2.0 - 1.0) * P.emitterHalf;
        } else {
            p.position = P.pointerActive != 0u ? P.pointer : float2(9.0, 9.0);
        }
        float angle = P.direction + (prand(id, gen, P.seed, 3u) - 0.5) * P.spread;
        float speed = mix(P.speedMin, P.speedMax, prand(id, gen, P.seed, 4u));
        p.velocity = speed * float2(cos(angle), sin(angle));
        p.size = 1.0 + (prand(id, gen, P.seed, 5u) * 2.0 - 1.0) * P.sizeJitter;
    }

    void burstParticle(thread Particle &p, uint id, constant ParticleParams &P) {
        uint gen = p.generation;
        p.life = mix(P.lifeMin, P.lifeMax, prand(id, gen, P.seed, 0u));
        p.position = P.burstPosition;
        float angle = prand(id, gen, P.seed, 3u) * 2.0 * M_PI_F;
        float speed = P.burstSpeed * (0.4 + 0.6 * prand(id, gen, P.seed, 4u));
        p.velocity = speed * float2(cos(angle), sin(angle));
        p.size = 1.0 + (prand(id, gen, P.seed, 5u) * 2.0 - 1.0) * P.sizeJitter;
        p.age = 0.0;
    }

    kernel void particleUpdate(device Particle *ps [[buffer(0)]],
                               constant ParticleParams &P [[buffer(1)]],
                               uint id [[thread_position_in_grid]]) {
        if (id >= P.count) return;
        Particle p = ps[id];

        if (P.initialize != 0u) {
            p.generation = 0u;
            spawnParticle(p, id, P);
            float r = prand(id, 0u, P.seed, 6u);
            if (P.prewarm != 0u) {
                p.age = r * p.life;
                p.position += p.velocity * p.age + 0.5 * P.gravity * p.age * p.age;
            } else {
                p.age = -r * p.life;
            }
            ps[id] = p;
            return;
        }

        if (P.burstCount > 0u && ((id - P.burstStart + P.count) % P.count) < P.burstCount) {
            p.generation += 1u;
            burstParticle(p, id, P);
        }
        p.age += P.dt;
        if (p.age < 0.0) { ps[id] = p; return; }
        if (p.age >= p.life) {
            p.generation += 1u;
            spawnParticle(p, id, P);
            p.age = 0.0;
        }

        float2 a = P.gravity;
        if (P.turbulence != 0.0) {
            float phase = float(pcg(id)) * (1.0 / 4294967296.0) * 6.2831853;
            a += P.turbulence * float2(sin(p.position.y * 7.0 + P.time * 1.3 + phase), cos(p.position.x * 7.0 + P.time * 1.1 + phase));
        }
        if (P.pointerMode != 0u && P.pointerActive != 0u) {
            float2 d = (p.position - P.pointer) * float2(P.simAspect, 1.0);
            float r = length(d);
            if (r < P.pointerRadius && r > 0.0001) {
                float k = (1.0 - r / P.pointerRadius) * (1.0 - r / P.pointerRadius) * P.pointerStrength;
                float2 dir = d / r;
                if (P.pointerMode == 1u) a -= dir * k;                       // attract
                else if (P.pointerMode == 2u) a += dir * k;                  // repel
                else a += float2(-dir.y, dir.x) * k;                         // swirl
            }
        }
        p.velocity += a * P.dt;
        p.velocity *= exp(-P.drag * P.dt);
        p.position += p.velocity * P.dt;
        ps[id] = p;
    }

    struct PVOut {
        float4 position [[position]];
        float2 uv;
        float4 color;
    };

    vertex PVOut particleVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                device const Particle *ps [[buffer(0)]],
                                constant ParticleParams &P [[buffer(1)]]) {
        const float2 corners[4] = { float2(-0.5, -0.5), float2(0.5, -0.5), float2(-0.5, 0.5), float2(0.5, 0.5) };
        Particle p = ps[iid];
        PVOut o;
        float t = p.age / max(p.life, 0.0001);
        bool hidden = p.age < 0.0 || t >= 1.0 || abs(p.position.x) > 4.0 || abs(p.position.y) > 4.0;
        if (hidden) {
            o.position = float4(3.0, 3.0, 0.0, 1.0);
            o.uv = float2(0.0);
            o.color = float4(0.0);
            return o;
        }
        float size = mix(P.sizeStart, P.sizeEnd, t) * p.size * (1.0 + P.keyBoost);
        float aspect = P.canvas.x / max(P.canvas.y, 1.0);
        float2 c = corners[vid];
        o.position = float4(p.position + c * 2.0 * size * float2(1.0 / aspect, 1.0), 0.0, 1.0);
        o.uv = c * 2.0;
        o.color = mix(P.colorStart, P.colorEnd, t);
        return o;
    }

    fragment float4 particleFragment(PVOut in [[stage_in]], constant ParticleParams &P [[buffer(1)]]) {
        float falloff = pow(saturate(1.0 - length(in.uv)), 1.6);
        float alpha = in.color.a * falloff * P.opacity;
        return float4(in.color.rgb * alpha, alpha);
    }
    """
}
