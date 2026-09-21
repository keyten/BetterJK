/*[Vertex]*/
void main()
{
	vec2 position = vec2(2.0 * float(gl_VertexID & 2) - 1.0, 4.0 * float(gl_VertexID & 1) - 1.0);
	gl_Position = vec4(position, 0.0, 1.0);
}

/*[Fragment]*/
// SSR ray march (tr_ssr.cpp, see ssr_common.glsl).
//
// For every receiver pixel (every pixel, or one of each 2x2 block at half resolution) the mirror
// reflection ray is marched through the linear depth buffer: in view space, projected to the screen
// with perspective correct depth (the view space ray and 1 / depth are linear in screen space, McGuire
// and Mara 2014), so the steps are evenly spread over the pixels the ray covers. The first crossing of
// a depth buffer surface (within its assumed thickness) is refined with a binary search.
//
// USE_HIZ walks the closest depth mips instead: cells the ray passes entirely in front of are skipped
// at once, the walk only descends to single pixels near surfaces.
//
// Output (RGBA16): xy = hit uv, z = hit distance / max ray length, w = confidence (0 = miss). The
// confidence fades the SSR towards the cubemap reflection where the hit is doubtful: near the screen
// edges, the end of the ray, back facing or ambiguous (thick) hits, rays towards the camera, grazing
// rays and rough surfaces.
//
// u_SSRSettings:  x = max steps, y = refine steps, z = max ray length, w = thickness
// u_SSRSettings2: x = max roughness, y = edge fade, z = pixel scale of the trace grid (1 or 2), w = frame
// u_SSRSettings3: x = coarsest Hi-Z level, y = min specular weight, z = near plane, w = Hi-Z iterations
// u_SSRTexelSize.xy = 1 / full resolution size

out vec4 out_Color;

#define MAX_LINEAR_STEPS 256
#define MAX_HIZ_ITERATIONS 1024
#define MAX_REFINE_STEPS 16

// ray: pixel g_S0 + g_D * s, 1 / view depth mix(g_k0, g_k1, s), s in [0, 1]
vec2 g_S0;
vec2 g_D;
float g_k0;
float g_k1;

vec2 RayPixel(float s)
{
	return g_S0 + g_D * s;
}

float RayDepth(float s)
{
	return 1.0 / mix(g_k0, g_k1, s);
}

float SceneDepth(vec2 pixel)
{
	return texelFetch(u_SSRHiZMap, ivec2(pixel), 0).r;
}

// the depth buffer only has the front of the surfaces, assume this much
// behind them is solid (grows with the distance, where depth is less precise)
float Thickness(float z)
{
	return u_SSRSettings.w * (1.0 + z * (1.0 / 512.0));
}

void main()
{
	out_Color = vec4(0.0);

	float gridScale = u_SSRSettings2.z;
	ivec2 fullSize = textureSize(u_SSRHiZMap, 0);
	ivec2 pix = ivec2(gl_FragCoord.xy) * int(gridScale);
	if (any(greaterThanEqual(pix, fullSize)))
		return;

	vec2 uv = (vec2(pix) + 0.5) * u_SSRTexelSize.xy;
	if (!SSRInsideView(uv))
		return;

	float z = texelFetch(u_SSRHiZMap, pix, 0).r;
	vec4 normalRoughness;
	if (!SSRIsReceiver(pix, z, normalRoughness))
		return;

	float roughness = normalRoughness.b;
	float maxRoughness = u_SSRSettings2.x;
	if (roughness >= maxRoughness)
		return;

	vec3 weight = SSRSpecularWeight(pix);
	if (max(weight.r, max(weight.g, weight.b)) < u_SSRSettings3.y)
		return;

	vec3 P = SSRViewPosition(uv, z);
	vec3 N = SSRViewNormal(normalRoughness.rg);
	vec3 V = -normalize(P);
	float NV = dot(N, V);
	if (NV <= 0.0)
		return;
	vec3 R = reflect(-V, N);

	// start slightly above the surface, stop in front of the near plane
	float startOffset = max(0.05, 0.002 * z);
	vec3 O = P + N * startOffset;
	float rayLength = u_SSRSettings.z * mix(1.0, 0.35, roughness / maxRoughness);
	float nearZ = u_SSRSettings3.z * 1.5;
	if (R.z < 0.0)
		rayLength = min(rayLength, (O.z - nearZ) / -R.z);
	if (rayLength <= 1.0 || O.z <= nearZ)
		return;
	vec3 E = O + R * rayLength;

	vec2 invTexel = 1.0 / u_SSRTexelSize.xy;
	g_S0 = SSRProjectToUV(O) * invTexel;
	vec2 S1 = SSRProjectToUV(E) * invTexel;
	g_D = S1 - g_S0;
	g_k0 = 1.0 / O.z;
	g_k1 = 1.0 / E.z;

	// clip the screen segment to the view rectangle (pixel centers)
	vec2 viewMin = u_SSRViewport.xy * invTexel + 0.5;
	vec2 viewMax = (u_SSRViewport.xy + u_SSRViewport.zw) * invTexel - 0.5;
	float sMax = 1.0;
	if (S1.x > viewMax.x) sMax = min(sMax, (viewMax.x - g_S0.x) / g_D.x);
	if (S1.x < viewMin.x) sMax = min(sMax, (viewMin.x - g_S0.x) / g_D.x);
	if (S1.y > viewMax.y) sMax = min(sMax, (viewMax.y - g_S0.y) / g_D.y);
	if (S1.y < viewMin.y) sMax = min(sMax, (viewMin.y - g_S0.y) / g_D.y);

	float screenLength = length(g_D);
	if (screenLength * sMax < 2.0)
		return; // along the view direction: nothing to find on the screen

	float jitter = SSRInterleavedGradientNoise(gl_FragCoord.xy + 5.588238 * u_SSRSettings2.w);

	// skip the pixels of the surface itself
	float sMin = min(1.5 / screenLength, sMax);

	bool hit = false;
	float lo = 0.0;
	float hi = 0.0;

#if !defined(USE_HIZ)
	float steps = min(u_SSRSettings.x, screenLength * sMax);
	float sPrev = sMin;
	float zPrev = RayDepth(sPrev);
	for (int i = 1; i <= MAX_LINEAR_STEPS; i++)
	{
		if (float(i) > steps)
			break;

		float s = sMin + (sMax - sMin) * (float(i) - 1.0 + jitter) / steps;
		float zRay = RayDepth(s);
		float zScene = SceneDepth(RayPixel(s));
		if (SSRIsSurface(zScene))
		{
			float zNear = min(zPrev, zRay);
			float zFar = max(zPrev, zRay);
			if (zFar >= zScene && zNear <= zScene + Thickness(zScene))
			{
				hit = true;
				lo = sPrev;
				hi = s;
				break;
			}
		}

		sPrev = s;
		zPrev = zRay;
	}
#else
	int maxLevel = int(u_SSRSettings3.x);
	int level = 0;
	float sEps = 0.02 / screenLength;
	float s = sMin + jitter / screenLength;
	vec2 dirStep = vec2(g_D.x >= 0.0 ? 1.0 : 0.0, g_D.y >= 0.0 ? 1.0 : 0.0);
	for (int i = 0; i < MAX_HIZ_ITERATIONS; i++)
	{
		if (float(i) >= u_SSRSettings3.w || s >= sMax)
			break;

		float cellSize = exp2(float(level));
		vec2 cell = floor(RayPixel(s) / cellSize);

		// where the ray leaves the cell
		vec2 boundary = (cell + dirStep) * cellSize;
		float sExitX = g_D.x != 0.0 ? (boundary.x - g_S0.x) / g_D.x : 1.0e30;
		float sExitY = g_D.y != 0.0 ? (boundary.y - g_S0.y) / g_D.y : 1.0e30;
		float sExit = min(min(sExitX, sExitY), sMax);

		ivec2 levelMax = textureSize(u_SSRHiZMap, level) - ivec2(1);
		float cellZ = texelFetch(u_SSRHiZMap, clamp(ivec2(cell), ivec2(0), levelMax), level).r;
		float zA = RayDepth(s);
		float zB = RayDepth(sExit);
		float zNear = min(zA, zB);
		float zFar = max(zA, zB);

		if (level > 0)
		{
			if (zFar < cellZ)
			{
				// entirely in front of everything in the cell
				s = sExit + sEps;
				level = min(level + 1, maxLevel);
			}
			else
			{
				level--;
			}
		}
		else
		{
			if (SSRIsSurface(cellZ) && zFar >= cellZ && zNear <= cellZ + Thickness(cellZ))
			{
				hit = true;
				lo = s;
				hi = sExit;
				break;
			}

			// in front: coarser again. Behind a surface: keep walking pixels
			if (zFar < cellZ || !SSRIsSurface(cellZ))
				level = min(level + 1, maxLevel);
			s = sExit + sEps;
		}
	}
#endif

	if (!hit)
		return;

	// binary search of the crossing
	for (int i = 0; i < MAX_REFINE_STEPS; i++)
	{
		if (float(i) >= u_SSRSettings.y)
			break;

		float mid = 0.5 * (lo + hi);
		float zScene = SceneDepth(RayPixel(mid));
		if (SSRIsSurface(zScene) && RayDepth(mid) >= zScene)
			hi = mid;
		else
			lo = mid;
	}

	float sHit = hi;
	vec2 hitPixel = RayPixel(sHit);
	vec2 hitUV = hitPixel * u_SSRTexelSize.xy;
	float zRay = RayDepth(sHit);
	float zScene = SceneDepth(hitPixel);
	if (!SSRIsSurface(zScene))
		return;

	// view space hit point (perspective correct) and the distance along the ray
	vec3 Q = mix(O * g_k0, E * g_k1, sHit) * zRay;
	float hitDistance = length(Q - O);
	if (hitDistance < 2.0 * startOffset)
		return; // the surface itself

	float confidence = 1.0;

	// ambiguous hit: the ray ended up far from the surface it crossed
	confidence *= 1.0 - smoothstep(0.25, 1.0, abs(zRay - zScene) / Thickness(zScene));

	// the ray sees the back of the surface it hit
	vec4 hitNormalRoughness;
	if (SSRIsReceiver(ivec2(hitPixel), zScene, hitNormalRoughness))
		confidence *= 1.0 - smoothstep(0.0, 0.35, dot(SSRViewNormal(hitNormalRoughness.rg), R));

	// screen edges: the reflection continues off screen
	if (u_SSRSettings2.y > 0.0)
	{
		vec2 rel = (hitUV - u_SSRViewport.xy) / u_SSRViewport.zw;
		float edge = min(min(rel.x, 1.0 - rel.x), min(rel.y, 1.0 - rel.y));
		confidence *= smoothstep(0.0, u_SSRSettings2.y, edge);
	}

	// near the end of the ray, where a miss starts
	confidence *= 1.0 - smoothstep(0.6, 1.0, hitDistance / rayLength);

	// back towards the camera: the reflected scene is mostly behind the view
	confidence *= 1.0 - smoothstep(0.4, 0.9, dot(R, V));

	// grazing views: the ray skims the (normal mapped) surface
	confidence *= smoothstep(0.0, 0.08, NV);

	// rough surfaces fade to the prefiltered cubemap
	confidence *= 1.0 - smoothstep(maxRoughness * 0.7, maxRoughness, roughness);

	out_Color = vec4(clamp(hitUV, 0.0, 1.0), clamp(hitDistance / u_SSRSettings.z, 0.0, 1.0), confidence);
}
