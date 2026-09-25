/*[Vertex]*/
void main()
{
	vec2 position = vec2(2.0 * float(gl_VertexID & 2) - 1.0, 4.0 * float(gl_VertexID & 1) - 1.0);
	gl_Position = vec4(position, 0.0, 1.0);
}

/*[Fragment]*/
// Skin subsurface scattering, r_skinSSS 2 (tr_skinsss.cpp, see ssr_common.glsl), full resolution.
//
// lightall writes the diffuse light of the skin stages (direct, sun, dynamic / area lights, ambient
// and diffuse IBL; never specular or emission) into attachment 7 of renderFbo:
//   rgb = skin diffuse * scatter (scene space, the space of color 0), a = view depth (0 = not skin)
// Color 0 still holds the sharp result. The separable passes diffuse that buffer with a skin profile,
// the composite swaps the sharp diffuse for the diffused one:
//
//   color += strength * (diffused - sharp)
//
// so specular highlights, eyes, metal, saber glow and everything that is not skin stay sharp.
//
// USE_HORIZONTAL / USE_VERTICAL: one direction of the diffusion.
//   u_SSRTraceMap = input (rgb skin diffuse, a = view depth), output the same layout.
//   Taps that are not skin, or not the visible surface (stale data, other depth), are replaced by the
//   centre; taps on the same skin fade towards the centre with their depth and normal difference
//   (follow surface), so the diffusion does not cross silhouettes (nose -> background), face -> hair or
//   skin -> cloth borders, and keeps its energy.
// USE_COMPOSITE: into color 0 of renderFbo (additive blending, or a plain write for debug views)
//   u_SSRHistoryMap = sharp skin diffuse, u_SSRTraceMap = diffused (vertical pass),
//   u_SSRSceneMap = horizontal pass (debug view 4).
//
// u_SkinKernel[i]: rgb = weight per channel (each channel sums to 1), a = offset in kernel radii; [0] is
//                  the centre tap.
// u_SkinSettings:  x = kernel radius in pixels at view depth 1, y = max radius (pixels),
//                  z = follow surface strength, w = taps
// u_SkinSettings2: x = kernel radius (world units), y = strength, z = split x (window pixels, < 0 off),
//                  w = debug view (r_skinSSSDebug)

#define SKIN_SSS_MAX_TAPS 25

uniform vec4 u_SkinKernel[SKIN_SSS_MAX_TAPS];
uniform vec4 u_SkinSettings;
uniform vec4 u_SkinSettings2;

out vec4 out_Color;

// the stored data belongs to the visible surface (as SSRIsReceiver)
bool SkinIsVisible(float storedDepth, float z)
{
	return storedDepth > 0.0 && SSRIsSurface(z) && abs(storedDepth - z) <= 0.02 * z + 1.0;
}

float SkinPixelRadius(float z)
{
	return min(u_SkinSettings.x / z, u_SkinSettings.y);
}

#if defined(USE_HORIZONTAL) || defined(USE_VERTICAL)
void main()
{
	ivec2 pix = ivec2(gl_FragCoord.xy);
	vec4 center = texelFetch(u_SSRTraceMap, pix, 0);
	out_Color = center;

	float z = texelFetch(u_SSRHiZMap, pix, 0).r;
	if (!SkinIsVisible(center.a, z))
		return;

	// distant characters: the profile is a pixel or less wide, nothing to diffuse
	float radius = SkinPixelRadius(z);
	if (radius < 0.5)
		return;

  #if defined(USE_HORIZONTAL)
	vec2 dir = vec2(radius, 0.0);
  #else
	vec2 dir = vec2(0.0, radius);
  #endif

	vec3 Nc = SSRDecodeNormal(texelFetch(u_SSRNormalMap, pix, 0).rg);
	ivec2 size = textureSize(u_SSRTraceMap, 0);
	float follow = u_SkinSettings.z;
	float invRadiusWorld = 1.0 / max(u_SkinSettings2.x, 1e-4);
	int taps = int(u_SkinSettings.w);

	vec3 sum = center.rgb * u_SkinKernel[0].rgb;
	for (int i = 1; i < SKIN_SSS_MAX_TAPS; i++)
	{
		if (i >= taps)
			break;

		vec2 p = gl_FragCoord.xy + dir * u_SkinKernel[i].a;
		ivec2 q = ivec2(floor(p));
		vec3 c = center.rgb;
		if (all(greaterThanEqual(q, ivec2(0))) && all(lessThan(q, size)) &&
			SSRInsideView((vec2(q) + 0.5) / vec2(size)))
		{
			vec4 s = texelFetch(u_SSRTraceMap, q, 0);
			float zs = texelFetch(u_SSRHiZMap, q, 0).r;
			if (SkinIsVisible(s.a, zs))
			{
				// follow surface: a depth step of one kernel radius or a strongly
				// bent normal stops the diffusion (the tap becomes the centre)
				vec3 Ns = SSRDecodeNormal(texelFetch(u_SSRNormalMap, q, 0).rg);
				float dz = abs(s.a - center.a) * invRadiusWorld;
				float dn = 1.0 - clamp(dot(Nc, Ns), 0.0, 1.0);
				c = mix(s.rgb, center.rgb, clamp(follow * (dz + dn), 0.0, 1.0));
			}
		}
		sum += c * u_SkinKernel[i].rgb;
	}

	out_Color = vec4(sum, center.a);
}
#endif

#if defined(USE_COMPOSITE)
vec3 SkinHeat(float t)
{
	t = clamp(t, 0.0, 1.0);
	return clamp(vec3(1.5 - abs(4.0 * t - 3.0), 1.5 - abs(4.0 * t - 2.0), 1.5 - abs(4.0 * t - 1.0)), 0.0, 1.0);
}

void main()
{
	ivec2 pix = ivec2(gl_FragCoord.xy);
	int view = int(u_SkinSettings2.w);
	out_Color = vec4(0.0);

	vec4 sharp = texelFetch(u_SSRHistoryMap, pix, 0);
	float z = texelFetch(u_SSRHiZMap, pix, 0).r;
	bool skin = SkinIsVisible(sharp.a, z);

	if (view >= 2)
	{
		// views other than 7 replace the color (no blending, alpha 1)
		vec3 d = texelFetch(u_SSRTraceMap, pix, 0).rgb - sharp.rgb;
		vec3 value = vec3(0.0);
		if (view == 7)
		{
			// additive: the scene minus the sharp skin diffuse, i.e. what stays sharp
			if (skin)
				out_Color = vec4(-sharp.rgb, 0.0);
			return;
		}
		if (skin)
		{
			if (view == 2)			// skin mask: scattering surfaces, shaded by their scatter amount
				value = vec3(1.0, 0.55, 0.4) * (0.25 + 0.75 * clamp(dot(sharp.rgb, vec3(0.2126, 0.7152, 0.0722)) * 4.0, 0.0, 1.0));
			else if (view == 3)		// raw (sharp) skin diffuse
				value = sharp.rgb;
			else if (view == 4)		// horizontal pass
				value = texelFetch(u_SSRSceneMap, pix, 0).rgb;
			else if (view == 5)		// vertical pass = diffused skin diffuse
				value = texelFetch(u_SSRTraceMap, pix, 0).rgb;
			else if (view == 6)		// final delta, luminance: red = gained, blue = lost (x8)
			{
				float l = dot(d, vec3(0.2126, 0.7152, 0.0722)) * u_SkinSettings2.y * 8.0;
				value = vec3(max(l, 0.0), 0.0, max(-l, 0.0)) + vec3(0.05);
			}
			else					// 8: kernel radius in pixels, 0 (blue) .. 16 (red); gray = no diffusion
			{
				float r = SkinPixelRadius(z);
				value = r < 0.5 ? vec3(0.3) : SkinHeat(r / 16.0);
			}
		}
		out_Color = vec4(value, 1.0);
		return;
	}

	if (!skin)
		return;

	// r_skinSSSCompare: left half without
	if (gl_FragCoord.x < u_SkinSettings2.z)
		return;

	vec3 diffused = texelFetch(u_SSRTraceMap, pix, 0).rgb;
	out_Color = vec4((diffused - sharp.rgb) * u_SkinSettings2.y, 0.0);
}
#endif
