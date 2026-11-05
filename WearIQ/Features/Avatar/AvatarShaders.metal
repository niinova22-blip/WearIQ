#include <metal_stdlib>
#include <RealityKit/RealityKit.h>
using namespace metal;

// Garments in RealityKit (AvatarRealityView): each vertex carries its fit colour, and how
// far it swings with the body's turn in uv0.x (the same weights as the SceneKit version).

// Turns each vertex round the vertical axis by the garment's lag (custom parameter x),
// as far as its sway weight lets it.
[[visible]]
void avatarSway(realitykit::geometry_parameters params)
{
    float w = params.geometry().uv0().x;
    float a = params.uniforms().custom_parameter().x * w;
    float3 p = params.geometry().model_position();
    float c = cos(a), s = sin(a);
    float3 q = float3(c * p.x + s * p.z, p.y, -s * p.x + c * p.z);
    params.geometry().set_model_position_offset(q - p);
}

// The fit colour (or the garment's own colour) as a matte fabric.
[[visible]]
void avatarFabric(realitykit::surface_parameters params)
{
    half4 c = half4(params.geometry().color());
    params.surface().set_base_color(c.rgb);
    params.surface().set_roughness(half(0.86));
    params.surface().set_metallic(half(0));
}

// Fit lines: unlit, bright, in their vertex colour.
[[visible]]
void avatarGlow(realitykit::surface_parameters params)
{
    half4 c = half4(params.geometry().color());
    // Unlit: what shows is the emissive colour (the base colour alone came out black).
    params.surface().set_base_color(c.rgb);
    params.surface().set_emissive_color(c.rgb);
    params.surface().set_opacity(c.a);
}
