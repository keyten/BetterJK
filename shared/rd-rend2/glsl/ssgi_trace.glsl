/*[Vertex]*/
void main()
{
	vec2 position = vec2(2.0 * float(gl_VertexID & 2) - 1.0, 4.0 * float(gl_VertexID & 1) - 1.0);
	gl_Position = vec4(position, 0.0, 1.0);
}

/*[Fragment]*/
// SSGI ray trace (tr_ssgi.cpp, see ssr_common.glsl).
//
// For every GI receiver (every pixel, or the lower left pixel of each 2x2 block at half resolution)
// u_SSRSettings2.x rays are shot in cosine weighted directions around the normal and marched through
// the depth buffer with the ray march shared with SSR (SSRMarchRay, USE_HIZ = hierarchical). The steps
// are denser near the receiver (short diffuse bounces matter most). A hit picks up the GI source
// radiance there (u_SSGISourceMap: dynamic diffuse light + emission, or the scene in the experimental
// full scene mode).
//
// With cosine weighted directions (pdf = cos / pi) the outgoing diffuse radiance of the receiver is
// albedo * mean(L): no cosine, no distance falloff (the solid angle of the source is in how often it
// is hit). The output is albedo free ("demodulated"), so the denoiser does not blur texture detail;
// the composite multiplies by the albedo. A miss adds nothing, it never darkens.
//
// The directions come from interleaved gradient noise (two decorrelated dimensions) rotated every
// frame by the R2 sequence: a stable, non-repeating pattern that the temporal filter averages.
//
// Output 0 (RGBA16F): rgb = mean(L * confidence), a = mean confidence.
// Output 1 (RG16F):   x = mean hit distance / max ray length, y = fraction of rays that hit.
//
// u_SSRSettings:  x = max steps, y = refine steps, z = max ray length, w = thickness
// u_SSRSettings2: x = rays, y = edge fade, z = pixel scale of the trace grid (1 or 2), w = frame
// u_SSRSettings3: x = coarsest Hi-Z level, y = coarsest source mip, z = near plane, w = Hi-Z iterations
// u_SSRTexelSize: xy = 1 / full resolution size, zw = uv scale full -> source texture

out vec4 out_Color;
out vec4 out_Glow;

#define SSGI_MAX_RAYS 8
// linear march: step distribution, > 1 = denser near the receiver
#define SSGI_STEP_POWER 1.6
// angular width of one ray sample (tangent), shrinks with more rays
#define SSGI_CONE_TANGENT 0.5

vec3 CosineDirection(vec3 N, vec2 u)
{
	vec3 T = normalize(abs(N.z) < 0.999 ? cross(N, vec3(0.0, 0.0, 1.0)) : cross(N, vec3(1.0, 0.0, 0.0)));
	vec3 B = cross(N, T);
	float r = sqrt(u.x);
	float phi = 6.28318531 * u.y;
	return normalize(T * (r * cos(phi)) + B * (r * sin(phi)) + N * sqrt(max(1.0 - u.x, 0.0)));
}

vec2 RayNoise(vec2 pixel, float frame, float rayIndex)
{
	vec2 p = pixel + rayIndex * vec2(37.0, 17.0);
	vec2 u = vec2(
		SSRInterleavedGradientNoise(p),
		SSRInterleavedGradientNoise(p.yx + vec2(113.0, 47.0)));
	// R2 sequence: per frame rotation of the pattern
	return fract(u + (frame + rayIndex * 0.5) * vec2(0.7548777, 0.5698403));
}

void main()
{
	out_Color = vec4(0.0);
	out_Glow = vec4(0.0);

	float gridScale = u_SSRSettings2.z;
	ivec2 fullSize = textureSize(u_SSRHiZMap, 0);
	ivec2 pix = ivec2(gl_FragCoord.xy) * int(gridScale);
	if (any(greaterThanEqual(pix, fullSize)))
		return;

	vec2 uv = (vec2(pix) + 0.5) * u_SSRTexelSize.xy;
	if (!SSRInsideView(uv))
		return;

	float z = texelFetch(u_SSRHiZMap, pix, 0).r;
	vec3 worldNormal;
	if (!SSGIIsReceiver(pix, z, worldNormal))
		return;

	vec3 P = SSRViewPosition(uv, z);
	vec3 N = normalize(mat3(u_SSRWorldToView) * worldNormal);

	// start slightly above the surface (no self intersection)
	float startOffset = max(0.05, 0.002 * z);
	vec3 O = P + N * startOffset;
	float nearZ = u_SSRSettings3.z * 1.5;
	if (O.z <= nearZ)
		return;

	float maxLength = u_SSRSettings.z;
	float thickness = u_SSRSettings.w;
	int rays = int(u_SSRSettings2.x);
	float frame = u_SSRSettings2.w;
	float coneTangent = SSGI_CONE_TANGENT / sqrt(max(u_SSRSettings2.x, 1.0));

	vec3 radiance = vec3(0.0);
	float confidenceSum = 0.0;
	float distanceSum = 0.0;
	float hits = 0.0;

	for (int r = 0; r < SSGI_MAX_RAYS; r++)
	{
		if (r >= rays)
			break;

		vec3 dir = CosineDirection(N, RayNoise(gl_FragCoord.xy, frame, float(r)));

		float rayLength = maxLength;
		if (dir.z < 0.0)
			rayLength = min(rayLength, (O.z - nearZ) / -dir.z);
		if (rayLength <= 1.0)
			continue;
		vec3 E = O + dir * rayLength;

		float sMin, sMax, screenLength;
		if (!SSRSetupRay(O, E, sMin, sMax, screenLength))
			continue;

		float jitter = SSRInterleavedGradientNoise(gl_FragCoord.xy + 5.588238 * frame + float(r) * 11.0);

		float sHit;
		if (!SSRMarchRay(sMin, sMax, screenLength, jitter,
			u_SSRSettings.x, SSGI_STEP_POWER, thickness, u_SSRSettings.y,
			u_SSRSettings3.x, u_SSRSettings3.w, sHit))
		{
			continue;
		}

		vec2 hitPixel = SSRRayPixel(sHit);
		vec2 hitUV = hitPixel * u_SSRTexelSize.xy;
		float zRay = SSRRayDepth(sHit);
		float zScene = SSRSceneDepth(hitPixel);
		if (!SSRIsSurface(zScene))
			continue;

		vec3 Q = mix(O * g_k0, E * g_k1, sHit) * zRay;
		float hitDistance = length(Q - O);
		if (hitDistance < 2.0 * startOffset)
			continue; // the surface itself

		float confidence = 1.0;

		// ambiguous hit: the ray ended up far behind the surface it crossed
		confidence *= 1.0 - smoothstep(0.25, 1.0, abs(zRay - zScene) / SSRThickness(zScene, thickness));

		// the back of the hit surface does not emit towards the receiver
		vec3 hitNormal;
		if (SSGIIsReceiver(ivec2(hitPixel), zScene, hitNormal))
			confidence *= 1.0 - smoothstep(0.0, 0.35, dot(normalize(mat3(u_SSRWorldToView) * hitNormal), dir));

		// screen edges: the geometry continues off screen
		if (u_SSRSettings2.y > 0.0)
		{
			vec2 rel = (hitUV - u_SSRViewport.xy) / u_SSRViewport.zw;
			float edge = min(min(rel.x, 1.0 - rel.x), min(rel.y, 1.0 - rel.y));
			confidence *= smoothstep(0.0, u_SSRSettings2.y, edge);
		}

		// near the end of the ray, where a miss starts
		confidence *= 1.0 - smoothstep(0.7, 1.0, hitDistance / maxLength);

		if (confidence <= 0.0)
			continue;

		// ray footprint at the hit (pixels) -> source mip (the source is half resolution)
		float footprint = 2.0 * hitDistance * coneTangent / (max(zScene, 1.0) * u_SSRDepthParams.w);
		float lod = clamp(log2(max(footprint * 0.5, 1.0)), 0.0, u_SSRSettings3.y);
		vec3 L = textureLod(u_SSGISourceMap, hitUV * u_SSRTexelSize.zw, lod).rgb;

		radiance += L * confidence;
		confidenceSum += confidence;
		distanceSum += hitDistance * confidence;
		hits += 1.0;
	}

	float invRays = 1.0 / max(float(rays), 1.0);
	out_Color = vec4(radiance, confidenceSum) * invRays;
	out_Glow = vec4(
		confidenceSum > 0.0 ? clamp(distanceSum / (confidenceSum * maxLength), 0.0, 1.0) : 0.0,
		hits * invRays, 0.0, 0.0);
}
