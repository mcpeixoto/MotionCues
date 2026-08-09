//
//  ParticleShaders.swift
//
//  The Metal shader, as source, compiled at launch.
//
//  It lives in a Swift string rather than a .metal file on purpose. Xcode
//  compiles any file it recognises as `sourcecode.metal` at build time, even
//  one added only to the Resources phase, and that requires the Metal
//  Toolchain component — a large separate download that a fresh Xcode install
//  and a CI runner do not have. Compiling from source at launch costs a few
//  milliseconds once, and in exchange `xcodebuild` works anywhere with no
//  extra setup.
//
//  One instanced quad per particle. The quad is stretched along the particle's
//  motion so a single primitive draws both the dot and its trail: the fragment
//  shader measures distance to a line segment, which degenerates to a circle
//  when the segment has zero length.
//
//  Each particle is drawn twice, dark and light, slightly offset. That is the
//  whole trick for staying visible over arbitrary content: we are not allowed
//  to see what is behind the overlay without Screen Recording permission, so
//  rather than guess the background we make sure one of the pair contrasts
//  with it whatever it is.
//

enum ParticleShaders {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 viewport;     // points
    float  globalAlpha;  // the user's opacity setting
    float  softness;     // edge feather in points
};

struct InstanceData {
    float2 head;     // current position, points, origin bottom-left
    float2 tail;     // previous position
    float  radius;   // points
    float  alpha;    // 0…1
    float4 colour;   // premultiplied-ready rgb + coverage multiplier in a
};

struct VertexOut {
    float4 position [[position]];
    float2 local;        // fragment position in the capsule's own space
    float2 tailLocal;
    float  radius;
    float4 colour;
};

// Unit quad, expanded on the CPU side to cover the capsule's bounding box.
constant float2 kCorners[4] = {
    float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0)
};

vertex VertexOut particle_vertex(uint vid [[vertex_id]],
                                 uint iid [[instance_id]],
                                 constant Uniforms &u [[buffer(0)]],
                                 constant InstanceData *instances [[buffer(1)]])
{
    InstanceData p = instances[iid];

    float2 centre = (p.head + p.tail) * 0.5;
    float2 span = (p.head - p.tail) * 0.5;
    // Bounding half-extent: the segment plus the cap radius, plus feather.
    float pad = p.radius + 2.0;
    // NB: `half` is a type in Metal (16-bit float), not a usable name.
    float2 halfExtent = abs(span) + float2(pad, pad);

    float2 corner = kCorners[vid];
    float2 pointPos = centre + corner * halfExtent;

    VertexOut out;
    // Points → clip space. Metal's NDC has +y up, which matches AppKit.
    float2 ndc = (pointPos / u.viewport) * 2.0 - 1.0;
    out.position = float4(ndc, 0.0, 1.0);
    out.local = pointPos - p.head;
    out.tailLocal = p.tail - p.head;
    out.radius = p.radius;
    out.colour = float4(p.colour.rgb, p.colour.a * p.alpha * u.globalAlpha);
    return out;
}

// Distance from point `p` to the segment from the origin to `b`.
static inline float segmentDistance(float2 p, float2 b)
{
    float len2 = dot(b, b);
    if (len2 < 1e-6) { return length(p); }
    float t = clamp(dot(p, b) / len2, 0.0, 1.0);
    return length(p - b * t);
}

fragment float4 particle_fragment(VertexOut in [[stage_in]],
                                  constant Uniforms &u [[buffer(0)]])
{
    float d = segmentDistance(in.local, in.tailLocal);
    // Feather the edge so dots do not alias, and so a fast-moving trail
    // dissolves rather than ending in a hard cap.
    float coverage = 1.0 - smoothstep(in.radius - u.softness, in.radius + u.softness, d);
    if (coverage <= 0.0) { discard_fragment(); }

    float a = in.colour.a * coverage;
    // Premultiplied alpha: the overlay window composites over live content.
    return float4(in.colour.rgb * a, a);
}
"""#
}
