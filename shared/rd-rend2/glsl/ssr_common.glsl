/*[Fragment]*/
// Shared by the ssr_*.glsl programs (screen-space reflections, tr_ssr.cpp).
//
// This file is not a program on its own: its fragment block is inserted into the fragment shaders of
// the SSR programs, see GLSL_LoadGPUProgramSSR.
//
// View space: x right, y up, z forward (positive linear depth), as in the screen-space AO passes.
//
// Material attachments of renderFbo, written by the opaque lightall stages (USE_SSR):
//   u_SSRNormalMap    RGB10_A2  rg = octahedral world normal, b = roughness, a = receiver
//   u_SSRSpecularMap  RGB10_A2  rgb = sqrt(W), W = specular IBL weight (F0 * EnvBRDF.x + EnvBRDF.y)
//   u_SSRCubemapMap   RGBA16F   rgb = cubemap reflection C that lightall added, a = view depth
//
// u_SSRHiZMap mip 0 holds the linear view depth of every pixel (SSR_DEPTH_VIEWMODEL for first person
// surfaces drawn with a hacked depth range, SSR_DEPTH_SKY where nothing was drawn), mips 1.. the
// closest depth of the 2x2 texels below (ignoring the view model).

uniform sampler2D u_ScreenDepthMap;    // hardware depth
uniform sampler2D u_SSRNormalMap;
uniform sampler2D u_SSRSpecularMap;
uniform sampler2D u_SSRCubemapMap;
uniform sampler2D u_SSRSceneMap;       // opaque scene color pyramid
uniform sampler2D u_SSRTraceMap;       // input of the pass
uniform sampler2D u_SSRHistoryMap;
uniform sampler2D u_SSRHistoryGeomMap;
uniform sampler2D u_SSRHiZMap;
uniform sampler2D u_VelocityMap;

uniform vec4 u_SSRProjection;   // P[0], P[5], P[8], P[9]
uniform vec4 u_SSRDepthParams;  // P[14], P[10], zFar, view space size of one pixel at depth 1
uniform vec4 u_SSRViewport;     // view rectangle in texture coordinates
uniform vec4 u_SSRTexelSize;    // 1 / source size, 1 / destination size
uniform vec4 u_SSRSettings;     // pass specific
uniform vec4 u_SSRSettings2;    // pass specific
uniform vec4 u_SSRSettings3;    // pass specific
uniform mat4 u_SSRWorldToView;
uniform mat4 u_SSRReproject;    // view space -> previous frame clip space

// RF_DEPTHHACK surfaces (first person weapon) are drawn with glDepthRange(0, 0.3)
#define SSR_DEPTH_HACK_MAX 0.3001
#define SSR_DEPTH_VIEWMODEL -1.0
#define SSR_DEPTH_SKY 1.0e20

vec3 SSRViewPosition(vec2 uv, float z)
{
	vec2 ndc = (uv - u_SSRViewport.xy) / u_SSRViewport.zw * 2.0 - 1.0;
	return vec3((ndc + u_SSRProjection.zw) * z / u_SSRProjection.xy, z);
}

vec2 SSRProjectToUV(vec3 p)
{
	vec2 ndc = p.xy * u_SSRProjection.xy / p.z - u_SSRProjection.zw;
	return (ndc * 0.5 + 0.5) * u_SSRViewport.zw + u_SSRViewport.xy;
}

bool SSRInsideView(vec2 uv)
{
	vec2 rel = (uv - u_SSRViewport.xy) / u_SSRViewport.zw;
	return all(greaterThanEqual(rel, vec2(0.0))) && all(lessThan(rel, vec2(1.0)));
}

vec2 SSREncodeNormal(vec3 n)
{
	n /= abs(n.x) + abs(n.y) + abs(n.z);
	vec2 e = n.xy;
	if (n.z < 0.0)
		e = (1.0 - abs(n.yx)) * vec2(n.x >= 0.0 ? 1.0 : -1.0, n.y >= 0.0 ? 1.0 : -1.0);
	return e * 0.5 + 0.5;
}

vec3 SSRDecodeNormal(vec2 e)
{
	e = e * 2.0 - 1.0;
	vec3 n = vec3(e, 1.0 - abs(e.x) - abs(e.y));
	float t = max(-n.z, 0.0);
	n.x += n.x >= 0.0 ? -t : t;
	n.y += n.y >= 0.0 ? -t : t;
	return normalize(n);
}

vec3 SSRViewNormal(vec2 encoded)
{
	return normalize(mat3(u_SSRWorldToView) * SSRDecodeNormal(encoded));
}

bool SSRIsSurface(float z)
{
	return z > 0.0 && z < SSR_DEPTH_SKY * 0.5;
}

// Pixel that gets screen-space reflections: an opaque PBR surface whose
// material data belongs to the visible surface (the stored view depth
// matches the depth buffer: not stale, not a hacked depth range)
bool SSRIsReceiver(ivec2 pix, float z, out vec4 normalRoughness)
{
	normalRoughness = texelFetch(u_SSRNormalMap, pix, 0);
	if (normalRoughness.a < 0.5 || !SSRIsSurface(z))
		return false;

	float storedDepth = texelFetch(u_SSRCubemapMap, pix, 0).a;
	return abs(storedDepth - z) <= 0.02 * z + 1.0;
}

vec3 SSRSpecularWeight(ivec2 pix)
{
	vec3 w = texelFetch(u_SSRSpecularMap, pix, 0).rgb;
	return w * w;
}

float SSRInterleavedGradientNoise(vec2 pixel)
{
	return fract(52.9829189 * fract(dot(pixel, vec2(0.06711056, 0.00583715))));
}

float SSRLuma(vec3 color)
{
	return dot(color, vec3(0.2126, 0.7152, 0.0722));
}

// tangent of the half angle of the reflection lobe: GGX alpha (roughness^2,
// as in the cubemap prefilter) as a Phong lobe (power 2 / alpha^2 - 2),
// angle holding most of its energy
float SSRConeTangent(float roughness)
{
	float a = max(roughness * roughness, 1.0e-3);
	float power = 2.0 / (a * a) - 2.0;
	float cosAngle = pow(0.244, 1.0 / (power + 1.0));
	return sqrt(max(1.0 - cosAngle * cosAngle, 0.0)) / cosAngle;
}
