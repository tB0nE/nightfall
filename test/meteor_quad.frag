// Cylinder/spherical ray mapping adapted from Monado layer.comp:
// Copyright 2021-2023, Collabora Ltd.
// Copyright 2025-2026, NVIDIA CORPORATION.
// SPDX-License-Identifier (adapted portions): BSL-1.0
#version 450
layout(set=0,binding=0) uniform sampler2D source_image;
struct LayerParameters {vec4 color_scale; vec4 color_bias; vec4 geometry;};
layout(set=0,binding=1,std430) readonly buffer LayerData {LayerParameters layers[];} parameters;
layout(push_constant) uniform Push {
    vec4 corner[4];
    vec4 uv_rect;
    vec4 color_scale;
    vec4 color_bias;
    uvec4 options;
} pc;
layout(location=0) in vec2 uv;
layout(location=0) out vec4 color;
layout(location=1) in vec3 panorama_ray;
void main() {
    vec2 sample_uv=uv;
    LayerParameters layer=parameters.layers[pc.options.z];
    vec4 geometry=layer.geometry;
    if (pc.options.y != 0u) {
        vec3 direction=normalize(panorama_ray);
        if(pc.options.y!=3u && geometry.w>0.0) {
            vec3 origin=pc.color_bias.xyz;
            bool cylinder=pc.options.y==2u;
            // Infinite vertical cylinder or sphere, in layer-local space.
            float a=cylinder ? dot(direction.xz,direction.xz) : 1.0;
            if(a<0.000001) discard;
            float b=cylinder ? dot(origin.xz,direction.xz) : dot(origin,direction);
            float c=(cylinder ? dot(origin.xz,origin.xz) : dot(origin,origin))-geometry.w*geometry.w;
            float determinant=b*b-a*c;
            if(determinant<0.0) discard;
            float distance=(-b+sqrt(determinant))/a;
            if(distance<=0.0) discard;
            direction=normalize(origin+direction*distance);
        }
        float longitude=atan(direction.x,-direction.z);
        vec2 spherical;
        if(pc.options.y==3u) {
            if(direction.z>=-0.000001) discard;
            vec2 tangent=direction.xy/-direction.z;
            spherical=vec2((tangent.x-geometry.x)/(geometry.y-geometry.x),
                (geometry.z-tangent.y)/(geometry.z-geometry.w));
        } else if(pc.options.y==2u) {
            float radial=length(direction.xz);
            if(radial<0.000001) discard;
            spherical=vec2(longitude/geometry.x+0.5,0.5-direction.y/radial*geometry.y/geometry.x);
        } else {
            float latitude=asin(clamp(direction.y,-1.0,1.0));
            spherical=vec2(longitude/geometry.x+0.5,(geometry.y-latitude)/(geometry.y-geometry.z));
        }
        if(any(lessThan(spherical,vec2(0))) || any(greaterThan(spherical,vec2(1)))) discard;
        sample_uv=pc.uv_rect.xy+spherical*pc.uv_rect.zw;
    }
    // Bound filtering to the submitted subrectangle, including atlased images.
    vec2 inset=0.5/vec2(textureSize(source_image,0));
    sample_uv=clamp(sample_uv,min(pc.uv_rect.xy,pc.uv_rect.xy+pc.uv_rect.zw)+inset,
        max(pc.uv_rect.xy,pc.uv_rect.xy+pc.uv_rect.zw)-inset);
    color = texture(source_image, sample_uv);
    if ((pc.options.x & 2u) == 0u) color.a = 1.0;
    if ((pc.options.x & 16u) != 0u) color = clamp(color * layer.color_scale + layer.color_bias,0.0,1.0);
    if ((pc.options.x & 4u) != 0u) color.rgb *= color.a;
}
