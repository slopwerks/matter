#version 460 core
#include <flutter/runtime_effect.glsl>

uniform vec2 u_size;
uniform vec4 u_bounds;
uniform vec2 u_direction;
uniform float u_sigma;
uniform float u_bottom;
uniform float u_inactive;
uniform sampler2D u_texture;
out vec4 frag_color;

vec4 sampleAt(vec2 point) {
  point = clamp(point, u_bounds.xy + vec2(0.5), u_bounds.xy + u_bounds.zw - vec2(0.5));
  vec2 uv = point / u_size;
#if defined(IMPELLER_TARGET_OPENGLES) && !defined(IMPELLER_OPENGLES_UNFLIPPED_DEPRECATED)
  uv.y = 1.0 - uv.y;
#endif
  return texture(u_texture, uv);
}

void main() {
  vec2 point = FlutterFragCoord().xy;
  float y = (point.y - u_bounds.y) / u_bounds.w;
  float edge = mix(1.0 - y, y, u_bottom);
  float strength = clamp((edge - u_inactive) / (1.0 - u_inactive), 0.0, 1.0);
  float sigma = u_sigma * strength * strength * strength;
  if (sigma < 0.1) {
    frag_color = sampleAt(point);
    return;
  }
  // Dense sampling of the reduced-resolution texture. Gaussian coefficients
  // advance by multiplication rather than evaluating exp() for every tap.
  float ratio = exp(-0.5 / (sigma * sigma));
  float acceleration = ratio * ratio;
  float weight = 1.0;
  float total = 1.0;
  vec4 color = sampleAt(point);
  float radius = min(ceil(sigma * 3.0), 64.0);
  for (int i = 1; i <= 64; i++) {
    if (float(i) > radius) break;
    weight *= ratio;
    ratio *= acceleration;
    vec2 offset = u_direction * float(i);
    color += (sampleAt(point - offset) + sampleAt(point + offset)) * weight;
    total += 2.0 * weight;
  }
  frag_color = color / total;
}
