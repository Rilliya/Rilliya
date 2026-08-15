#include <metal_stdlib>
using namespace metal;

struct Uniforms {
  float2 viewportSize;
  float2 cameraOffset;
  float4 backgroundColor;
  float4 gridColor;
  float zoom;
  float3 padding;
};

struct ShapeInstance {
  float2 origin;
  float2 size;
  float4 fillColor;
  float4 borderColor;
  float cornerRadius;
  float borderWidth;
  float opacity;
  float padding;
};

struct TriangleInstance {
  float2 point0;
  float2 point1;
  float2 point2;
  float2 padding;
  float4 color;
};

struct AtlasInstance {
  float2 origin;
  float2 size;
  float2 textureOrigin;
  float2 textureSize;
  float4 color;
  float opacity;
  uint textureKind;
  float2 padding;
};

struct GridOutput {
  float4 position [[position]];
  float2 viewportPoint;
};

struct ShapeOutput {
  float4 position [[position]];
  float2 uv;
  float2 pixelSize;
  float4 fillColor [[flat]];
  float4 borderColor [[flat]];
  float cornerRadius [[flat]];
  float borderWidth [[flat]];
  float opacity [[flat]];
};

struct FlatOutput {
  float4 position [[position]];
  float4 color [[flat]];
};

struct AtlasOutput {
  float4 position [[position]];
  float2 uv;
  float4 color [[flat]];
  float opacity [[flat]];
  uint textureKind [[flat]];
};

constant float2 quadVertices[6] = {
  float2(0, 0), float2(1, 0), float2(0, 1),
  float2(0, 1), float2(1, 0), float2(1, 1)
};

float4 viewportPosition(float2 worldPoint, constant Uniforms &uniforms) {
  float2 viewportPoint = worldPoint * uniforms.zoom + uniforms.cameraOffset;
  return float4(
    viewportPoint.x / uniforms.viewportSize.x * 2 - 1,
    1 - viewportPoint.y / uniforms.viewportSize.y * 2,
    0,
    1
  );
}

vertex GridOutput gridVertex(uint vertexID [[vertex_id]]) {
  float2 uv = quadVertices[vertexID];
  GridOutput output;
  output.position = float4(uv.x * 2 - 1, 1 - uv.y * 2, 0, 1);
  output.viewportPoint = uv;
  return output;
}

fragment float4 gridFragment(
  GridOutput input [[stage_in]],
  constant Uniforms &uniforms [[buffer(0)]]
) {
  float2 viewportPoint = input.viewportPoint * uniforms.viewportSize;
  float2 worldPoint = (viewportPoint - uniforms.cameraOffset) / uniforms.zoom;
  float baseVisualSpacing = max(24.0 * uniforms.zoom, 0.001);
  float levelScale = exp2(ceil(log2(13.0 / baseVisualSpacing)));
  float spacing = 24.0 * levelScale;
  float2 cell = (fract(worldPoint / spacing + 0.5) - 0.5) * spacing * uniforms.zoom;
  float fine = 1.0 - smoothstep(0.55, 1.35, length(cell));
  float2 coarseCell =
    (fract(worldPoint / (spacing * 2.0) + 0.5) - 0.5) * spacing * 2.0 * uniforms.zoom;
  float coarse = 1.0 - smoothstep(0.65, 1.55, length(coarseCell));
  float strength = max(fine * 0.20, coarse * 0.31);
  return float4(mix(uniforms.backgroundColor.rgb, uniforms.gridColor.rgb, strength), 1);
}

vertex ShapeOutput shapeVertex(
  uint vertexID [[vertex_id]],
  uint instanceID [[instance_id]],
  constant Uniforms &uniforms [[buffer(0)]],
  constant ShapeInstance *instances [[buffer(1)]]
) {
  ShapeInstance instance = instances[instanceID];
  float2 uv = quadVertices[vertexID];
  ShapeOutput output;
  output.position = viewportPosition(instance.origin + uv * instance.size, uniforms);
  output.uv = uv;
  output.pixelSize = max(instance.size * uniforms.zoom, float2(1));
  output.fillColor = instance.fillColor;
  output.borderColor = instance.borderColor;
  output.cornerRadius = instance.cornerRadius * uniforms.zoom;
  output.borderWidth = instance.borderWidth * uniforms.zoom;
  output.opacity = instance.opacity;
  return output;
}

fragment float4 shapeFragment(ShapeOutput input [[stage_in]]) {
  float radius = min(input.cornerRadius, min(input.pixelSize.x, input.pixelSize.y) * 0.5);
  float2 point = (input.uv - 0.5) * input.pixelSize;
  float2 bounds = input.pixelSize * 0.5 - radius;
  float2 delta = abs(point) - bounds;
  float distance = length(max(delta, 0.0)) + min(max(delta.x, delta.y), 0.0) - radius;
  float coverage = 1.0 - smoothstep(-0.55, 0.7, distance);
  float border = input.borderWidth > 0
    ? smoothstep(-input.borderWidth - 0.6, -input.borderWidth + 0.35, distance)
    : 0.0;
  float4 color = mix(input.fillColor, input.borderColor, border);
  color.a *= coverage * input.opacity;
  return color;
}

vertex FlatOutput triangleVertex(
  uint vertexID [[vertex_id]],
  uint instanceID [[instance_id]],
  constant Uniforms &uniforms [[buffer(0)]],
  constant TriangleInstance *instances [[buffer(1)]]
) {
  TriangleInstance instance = instances[instanceID];
  float2 point = vertexID == 0 ? instance.point0 : (vertexID == 1 ? instance.point1 : instance.point2);
  FlatOutput output;
  output.position = viewportPosition(point, uniforms);
  output.color = instance.color;
  return output;
}

fragment float4 flatFragment(FlatOutput input [[stage_in]]) {
  return input.color;
}

vertex AtlasOutput atlasVertex(
  uint vertexID [[vertex_id]],
  uint instanceID [[instance_id]],
  constant Uniforms &uniforms [[buffer(0)]],
  constant AtlasInstance *instances [[buffer(1)]]
) {
  AtlasInstance instance = instances[instanceID];
  float2 corner = quadVertices[vertexID];
  AtlasOutput output;
  output.position = viewportPosition(instance.origin + corner * instance.size, uniforms);
  output.uv = instance.textureOrigin + float2(corner.x, 1 - corner.y) * instance.textureSize;
  output.color = instance.color;
  output.opacity = instance.opacity;
  output.textureKind = instance.textureKind;
  return output;
}

fragment float4 atlasFragment(
  AtlasOutput input [[stage_in]],
  texture2d<float> glyphAtlas [[texture(0)]],
  texture2d<float> colorAtlas [[texture(1)]]
) {
  constexpr sampler textureSampler(filter::linear, address::clamp_to_edge);
  if (input.textureKind == 0) {
    float coverage = glyphAtlas.sample(textureSampler, input.uv).r;
    return float4(input.color.rgb, input.color.a * coverage * input.opacity);
  }
  float4 sample = colorAtlas.sample(textureSampler, input.uv);
  sample *= input.color;
  sample.a *= input.opacity;
  return sample;
}
