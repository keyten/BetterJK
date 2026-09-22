/*[Fragment]*/
// Froxel volumetric fog (r_volumetricFog 2), tr_volumetric.cpp, docs/rend2-volumetric-fog.md.
//
// This file is not a program on its own: its fragment block is inserted into the fragment shaders of
// the volumetric_*.glsl programs and, with r_volumetricFog 2 only, of the fog pass, generic and
// surface sprite programs (the legacy fog paths). Everything is inside USE_FROXEL_FOG.
//
// Froxel volume: froxels x, y cover the main view, z is split in slices with exponential distances:
// slice k spans the view depths [B(k), B(k + 1)], B(k) = near * (far / near)^(k / N), and slice 0
// starts at the camera. View depth is the distance along the view forward axis.
//
//   u_FroxelVolume  RGBA16F 3D  rgb = light scattered towards the camera between the camera and
//                               the far side of the slice (B(k + 1)), a = transmittance
//   u_FroxelTail    RGBA16F 2D  rgb = radiance, a = extinction of the last slice (beyond far)
//
// Units: extinction per world unit, as depthToOpaque of the legacy volumetric fog.

#if defined(USE_FROXEL_FOG)
layout(std140) uniform VolumetricFog
{
	mat4 u_FroxelViewProjection;		// froxel camera (main view without jitter)
	mat4 u_FroxelInvViewProjection;		// inverse of the rendered view projection
	mat4 u_FroxelPrevViewProjection;	// froxel camera of the history volume
	vec4 u_FroxelViewOrigin;			// w: 1 = volume available
	vec4 u_FroxelViewForward;
	vec4 u_FroxelRayForward;			// ray of a froxel = rayForward + ndc.x * rayRight + ndc.y * rayUp
	vec4 u_FroxelRayRight;
	vec4 u_FroxelRayUp;
	vec4 u_FroxelViewport;				// view rectangle in render target texture coordinates
	vec4 u_FroxelSliceParams;			// near, far, log2(far / near), sky distance
	vec4 u_FroxelGridSize;				// froxels x, y, z, frame index
	vec4 u_FroxelJitter;				// jitter in froxel units, w: temporal accumulation
	vec4 u_FroxelTemporalParams;		// history weight, history valid, unused, radiance clamp ratio
	vec4 u_FroxelLightParams;			// anisotropy g, sun scale, dynamic light scale, baked light scale
	vec4 u_FroxelSunColor;				// realtime sun radiance, w: cascaded shadow maps available
	vec4 u_FroxelSunDirection;			// towards the sun, w: split light grid available
	vec4 u_FroxelGridOrigin;			// light grid sample origin, w: vertical cell size
	vec4 u_FroxelGridScale;				// world to light grid texture coordinates, w: horizontal cell size
	vec4 u_FroxelShadowParams;			// cascade far distance, shadow map size, dlight shadows, bias
	vec4 u_FroxelDebugParams;			// debug view, bloom, frozen volume, unused
	int u_FroxelNumFogs;
	vec4 u_FroxelFogColor[MAX_GPU_FOGS];	// rgb albedo (fog color), a: extinction
	vec4 u_FroxelFogPlane[MAX_GPU_FOGS];
	vec4 u_FroxelFogMins[MAX_GPU_FOGS];		// w: has plane
	vec4 u_FroxelFogMaxs[MAX_GPU_FOGS];
};

uniform sampler3D u_FroxelVolume;
uniform sampler2D u_FroxelTail;

// 0 = legacy fog, 1 = froxel volume lookup, 2 = none (the composite applied it)
uniform int u_FroxelFogMode;

#define FROXEL_DEPTH_HACK_MAX 0.3001

// view depth of the slice coordinate w (0 = near, 1 = far)
float FroxelWToDepth(in float w)
{
	return u_FroxelSliceParams.x * exp2(w * u_FroxelSliceParams.z);
}

// slice coordinate of the view depth d
float FroxelDepthToW(in float d)
{
	return log2(max(d, u_FroxelSliceParams.x) / u_FroxelSliceParams.x) / u_FroxelSliceParams.z;
}

// Henyey-Greenstein phase function times 4 pi: 1 for isotropic scattering (g = 0), so the anisotropy
// redistributes the scattered light without changing its average. cosTheta: angle between the light
// propagation direction and the direction towards the camera.
float FroxelPhase(in float g, in float cosTheta)
{
	float g2 = g * g;
	float denom = max(1.0 + g2 - 2.0 * g * cosTheta, 1e-4);
	return (1.0 - g2) / (denom * sqrt(denom));
}

// In-scattering (rgb) and transmittance (a) between the camera and the view depth d, along the ray
// through uv (froxel volume texture coordinates). rayScale: path length per unit of view depth.
vec4 FroxelLookup(in vec2 uv, in float d, in float rayScale)
{
	float numSlices = u_FroxelGridSize.z;
	float farZ = u_FroxelSliceParams.y;
	float firstBoundary = FroxelWToDepth(1.0 / numSlices);

	float dc = clamp(d, 0.0, farZ);
	// texel k holds the value at B(k + 1)
	float b = FroxelDepthToW(max(dc, firstBoundary)) * numSlices;
	vec4 fog = texture(u_FroxelVolume, vec3(uv, (b - 0.5) / numSlices));

	// the first slice starts at the camera
	if (dc < firstBoundary)
		fog = mix(vec4(0.0, 0.0, 0.0, 1.0), fog, dc / firstBoundary);

	// beyond the slices: the medium of the last slice continues
	if (d > farZ)
	{
		vec4 tail = texture(u_FroxelTail, uv);
		float t = exp(-tail.a * (d - farZ) * rayScale);
		fog.rgb += fog.a * tail.rgb * (1.0 - t);
		fog.a *= t;
	}

	return fog;
}

// In-scattering (rgb) and transmittance (a) between the camera and worldPos
vec4 FroxelFog(in vec3 worldPos)
{
	vec4 clip = u_FroxelViewProjection * vec4(worldPos, 1.0);
	if (clip.w <= 0.0)
		return vec4(0.0, 0.0, 0.0, 1.0);

	vec2 uv = (clip.xy / clip.w) * 0.5 + 0.5;
	vec3 toPos = worldPos - u_FroxelViewOrigin.xyz;
	float d = dot(toPos, u_FroxelViewForward.xyz);
	float rayScale = length(toPos) / max(d, 1e-3);

	// a frozen volume (r_volumetricFogFreeze) only covers its own frustum
	if (u_FroxelDebugParams.z > 0.5 && (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))))
		return vec4(0.0, 0.0, 0.0, 1.0);

	return FroxelLookup(clamp(uv, 0.0, 1.0), d, rayScale);
}

// World position of the depth buffer sample at render target coordinates tc. The first person view
// model (depth hack range) is moved back to its real depth, the sky is at the sky distance.
vec3 FroxelSceneWorldPosition(in vec2 tc, in float depth)
{
	vec2 ndc = (tc - u_FroxelViewport.xy) / u_FroxelViewport.zw * 2.0 - 1.0;

	if (depth >= 1.0)
	{
		vec4 farPoint = u_FroxelInvViewProjection * vec4(ndc, 1.0, 1.0);
		vec3 dir = farPoint.xyz / farPoint.w - u_FroxelViewOrigin.xyz;
		dir /= max(dot(dir, u_FroxelViewForward.xyz), 1e-6);
		return u_FroxelViewOrigin.xyz + dir * u_FroxelSliceParams.w;
	}

	if (depth <= FROXEL_DEPTH_HACK_MAX)
		depth /= 0.3;

	vec4 p = u_FroxelInvViewProjection * vec4(ndc, depth * 2.0 - 1.0, 1.0);
	return p.xyz / p.w;
}
#endif
