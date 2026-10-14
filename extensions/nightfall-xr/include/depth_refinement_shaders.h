// Bounded-2 / Bounded-4, matching the model_tester experiments.
// Alignment reads the upright source colour through its SurfaceTexture matrix.
#pragma once
static const char *EDGE_ALIGNMENT_FRAGMENT_SRC = R"NFGLSL(#version 300 es
#ifndef NIGHTFALL_TEXTURE_2D
#extension GL_OES_EGL_image_external_essl3 : require
#define NIGHTFALL_GUIDE samplerExternalOES
#else
#define NIGHTFALL_GUIDE sampler2D
#endif
precision highp float;
precision highp sampler2D;
in vec2 v_plain;
uniform sampler2D u_depth;
uniform highp NIGHTFALL_GUIDE u_guide;
uniform mat4 u_texmatrix;
vec4 sample_guide(vec2 uv) { return texture(u_guide, (u_texmatrix * vec4(uv, 0.0, 1.0)).xy); }
uniform float u_radius;
uniform float u_strength;
out vec4 fragColor;
void unchanged(float base) {
#ifdef BOUNDED3_FIELD
    fragColor = vec4(0.0,0.0,0.0,base);
#else
    fragColor = vec4(base);
#endif
}
void main() {
    vec2 texel = 1.0 / vec2(textureSize(u_depth, 0));
    float base = texture(u_depth, v_plain).r;
    vec2 g = vec2(texture(u_depth, v_plain + vec2(texel.x,0)).r - texture(u_depth, v_plain - vec2(texel.x,0)).r,
                  texture(u_depth, v_plain + vec2(0,texel.y)).r - texture(u_depth, v_plain - vec2(0,texel.y)).r);
    float magnitude = length(g);
    if (magnitude < 0.015 || u_strength == 0.0 || u_radius == 0.0) { unchanged(base); return; }
    // Work in native depth texels, so the bound has a meaningful fixed size.
    vec2 stepUV = normalize(g) * texel;
    float depthSum = 0.0, depthWeight = 0.0;
    for (int i = -4; i <= 4; ++i) {
        float s = float(i) * u_radius / 4.0;
        vec2 q = v_plain + stepUV * s;
        float score = abs(texture(u_depth, q + stepUV * 0.5).r - texture(u_depth, q - stepUV * 0.5).r);
        float w = pow(score, 4.0);
        depthSum += s * w;
        depthWeight += w;
    }
    float depthPosition = depthSum / max(depthWeight, 1e-12);
    float colourSum = 0.0, colourWeight = 0.0, peakColour = 0.0;
#ifdef BOUNDED3_FIELD
    float colourMoment2 = 0.0;
#endif
    for (int i = -4; i <= 4; ++i) {
        float s = float(i) * u_radius / 4.0;
        vec2 q = v_plain + stepUV * s;
        vec3 gx = sample_guide( q + vec2(texel.x*0.5,0)).rgb - sample_guide( q - vec2(texel.x*0.5,0)).rgb;
        vec3 gy = sample_guide( q + vec2(0,texel.y*0.5)).rgb - sample_guide( q - vec2(0,texel.y*0.5)).rgb;
        vec3 along = gx * normalize(g).x + gy * normalize(g).y;
        float energy = dot(gx,gx) + dot(gy,gy);
        float orientation = dot(along,along) / max(energy, 1e-8);
        float contrast = length(along);
        float prior = exp(-pow((s-depthPosition)/max(u_radius,0.001),2.0)*2.0);
        float w = pow(contrast,4.0) * smoothstep(0.65,0.9,orientation) * prior;
        colourSum += s*w;
#ifdef BOUNDED3_FIELD
        colourMoment2 += s*s*w;
#endif
        colourWeight += w;
        peakColour = max(peakColour, contrast * smoothstep(0.65,0.9,orientation));
    }
    if (colourWeight < 1e-10) { unchanged(base); return; }
    float colourPosition = colourSum / colourWeight;
    float confidence = smoothstep(0.015,0.06,magnitude) * smoothstep(0.06,0.2,peakColour);
#ifdef BOUNDED3_FIELD
    // Multiple competing peaks, or a broadly uncertain colour boundary: fade
    // back toward linear instead of averaging two unrelated candidate edges.
    float variance = max(colourMoment2/colourWeight-colourPosition*colourPosition,0.0);
    confidence *= 1.0-smoothstep(0.45,1.2,variance);
#endif
    float shift = clamp(depthPosition-colourPosition, -u_radius, u_radius) * confidence * u_strength;
#ifdef BOUNDED3_FIELD
    // Signed native-depth-texel displacement and confidence, NOT an 8-bit map.
    fragColor = vec4(normalize(g)*shift,confidence,base);
#else
    float d = texture(u_depth, v_plain + stepUV*shift).r;
    fragColor = vec4(d);
#endif
}
)NFGLSL";
static const char *CONTOUR_CLEANUP_FRAGMENT_SRC = R"NFGLSL(#version 300 es
precision highp float;
precision highp sampler2D;
// Bounded-4 LOCAL experiment: tangent-only cleanup of Bounded-2 depth.
// No colour texture is used, so cleanup cannot follow text/texture edges.
in vec2 v_plain;
uniform sampler2D u_depth;
out vec4 fragColor;
void main() {
    vec2 t = 1.0/vec2(textureSize(u_depth,0));
    float centre = texture(u_depth,v_plain).r;
    float tl = texture(u_depth,v_plain+vec2(-t.x,-t.y)).r;
    float tc = texture(u_depth,v_plain+vec2(0,-t.y)).r;
    float tr = texture(u_depth,v_plain+vec2(t.x,-t.y)).r;
    float ml = texture(u_depth,v_plain+vec2(-t.x,0)).r;
    float mr = texture(u_depth,v_plain+vec2(t.x,0)).r;
    float bl = texture(u_depth,v_plain+vec2(-t.x,t.y)).r;
    float bc = texture(u_depth,v_plain+vec2(0,t.y)).r;
    float br = texture(u_depth,v_plain+vec2(t.x,t.y)).r;
    vec2 g = vec2(tr+2.0*mr+br-tl-2.0*ml-bl,bl+2.0*bc+br-tl-2.0*tc-tr)*0.25;
    float magnitude = length(g);
    if (magnitude < 0.015) { fragColor = vec4(centre); return; }
    vec2 normal = normalize(g);
    vec2 tangent = vec2(-normal.y,normal.x)*t;
    float lo = min(min(min(tl,tr),min(bl,br)),min(min(tc,bc),min(ml,mr)));
    float hi = max(max(max(tl,tr),max(bl,br)),max(max(tc,bc),max(ml,mr)));
    float minusDepth = texture(u_depth,v_plain-normal*t*2.0).r;
    float plusDepth = texture(u_depth,v_plain+normal*t*2.0).r;
    // Reject narrow ridges/valleys whose two sides return to the same depth.
    float thinGuard = smoothstep(0.4,0.85,abs(plusDepth-minusDepth)/max(hi-lo,1e-5));
    float sum = centre*6.0;
    for (int i = -2; i <= 2; ++i) {
        if (i == 0) continue;
        sum += texture(u_depth,v_plain+tangent*float(i)).r*(abs(i)==1 ? 4.0 : 1.0);
    }
    float gate = smoothstep(0.015,0.06,magnitude)*thinGuard*0.85;
    float delta = clamp(sum/16.0-centre,-min(0.08,magnitude*0.4),min(0.08,magnitude*0.4));
    fragColor = vec4(clamp(centre+gate*delta,lo,hi));
}
)NFGLSL";
