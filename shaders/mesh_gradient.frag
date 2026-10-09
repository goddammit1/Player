#version 460 core

// Mesh-фон страницы плеера: четыре размытых пятна цветов обложки, цвета
// смешиваются по весам расстояния. Внизу фон темнее — там управление.
// Центры пятен считает MeshBackground на CPU, порядок uniform совпадает с ним.

#include <flutter/runtime_effect.glsl>

// highp: в mediump (fp16 на мобильных GPU) хэш дизеринга переполняется
// на высоких экранах, а плавные переходы ступенчатые.
precision highp float;

uniform vec2 uSize;
// Центры пятен в долях экрана (x — доля ширины, y — доля высоты).
uniform vec2 uCenter0;
uniform vec2 uCenter1;
uniform vec2 uCenter2;
uniform vec2 uCenter3;
uniform vec4 uColor0;
uniform vec4 uColor1;
uniform vec4 uColor2;
uniform vec4 uColor3;

out vec4 fragColor;

float weight(vec2 p, vec2 center, float aspect) {
  vec2 d = p - vec2(center.x * aspect, center.y);
  return 1.0 / (dot(d, d) * 6.0 + 0.04);
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 uv = frag / uSize;
  float aspect = uSize.x / uSize.y;
  vec2 p = vec2(uv.x * aspect, uv.y);

  float w0 = weight(p, uCenter0, aspect);
  float w1 = weight(p, uCenter1, aspect);
  float w2 = weight(p, uCenter2, aspect);
  float w3 = weight(p, uCenter3, aspect);
  vec3 color = (uColor0.rgb * w0 + uColor1.rgb * w1 + uColor2.rgb * w2 +
                uColor3.rgb * w3) / (w0 + w1 + w2 + w3);

  color *= mix(1.0, 0.55, smoothstep(0.45, 1.0, uv.y));

  // Дизеринг против полос на тёмных плавных переходах.
  float noise = fract(sin(dot(frag, vec2(12.9898, 78.233))) * 43758.5453);
  color += (noise - 0.5) / 255.0;

  fragColor = vec4(color, 1.0);
}
