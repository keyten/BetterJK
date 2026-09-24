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
// with perspective correct depth, the steps evenly spread over the pixels the ray covers (SSRMarchRay,
// shared with SSGI; USE_HIZ walks the closest depth mips). The first crossing of a depth buffer surface
// (within its assumed thickness) is refined with a binary search.
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

	float sMin, sMax, screenLength;
	if (!SSRSetupRay(O, E, sMin, sMax, screenLength))
		return; // along the view direction: nothing to find on the screen

	float jitter = SSRInterleavedGradientNoise(gl_FragCoord.xy + 5.588238 * u_SSRSettings2.w);

	float sHit;
	if (!SSRMarchRay(sMin, sMax, screenLength, jitter,
		u_SSRSettings.x, 1.0, u_SSRSettings.w, u_SSRSettings.y,
		u_SSRSettings3.x, u_SSRSettings3.w, sHit))
	{
		return;
	}

	vec2 hitPixel = SSRRayPixel(sHit);
	vec2 hitUV = hitPixel * u_SSRTexelSize.xy;
	float zRay = SSRRayDepth(sHit);
	float zScene = SSRSceneDepth(hitPixel);
	if (!SSRIsSurface(zScene))
		return;

	// view space hit point (perspective correct) and the distance along the ray
	vec3 Q = mix(O * g_k0, E * g_k1, sHit) * zRay;
	float hitDistance = length(Q - O);
	if (hitDistance < 2.0 * startOffset)
		return; // the surface itself

	float confidence = 1.0;

	// ambiguous hit: the ray ended up far from the surface it crossed
	confidence *= 1.0 - smoothstep(0.25, 1.0, abs(zRay - zScene) / SSRThickness(zScene, u_SSRSettings.w));

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
