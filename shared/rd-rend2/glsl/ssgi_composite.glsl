/*[Vertex]*/
void main()
{
	vec2 position = vec2(2.0 * float(gl_VertexID & 2) - 1.0, 4.0 * float(gl_VertexID & 1) - 1.0);
	gl_Position = vec4(position, 0.0, 1.0);
}

/*[Fragment]*/
// SSGI upsample + composite (tr_ssgi.cpp, see ssr_common.glsl), full resolution, into color 0 of
// renderFbo (additive blending).
//
// Half resolution GI is upsampled from the four nearest trace texels, weighted by their bilinear
// position, depth and normal similarity (as the SSR resolve): GI does not leak across silhouettes or
// corners. The receiver's diffuse albedo (after the metalness split) turns the albedo free GI into
// outgoing radiance:
//
//   indirect = albedo * GI * r_ssgiIntensity                  (linear HDR)
//   linear scene:  color += indirect
//   legacy scene:  color += Enc(Dec(color) + indirect) - color  (display encoded buffer, as emission)
//
// u_SSRTraceMap = GI (rgb, confidence), u_SSRSceneMap = copy of the scene color (legacy scene only).
// u_SSRSettings:  x = intensity, y = split screen x (window pixels, < 0 = off), z = mode
//                 (0 add, 1 show GI, 2 show GI source radiance, 3 show indirect), w = 1 linear scene
// u_SSRSettings2: x = trace grid scale
// u_SSRTexelSize: xy = 1 / full resolution size

out vec4 out_Color;

vec4 UpsampleGI(ivec2 pix, float z, vec3 N)
{
	int grid = int(u_SSRSettings2.x);
	if (grid <= 1)
		return texelFetch(u_SSRTraceMap, pix, 0);

	ivec2 fullSize = textureSize(u_SSRHiZMap, 0);
	ivec2 traceMax = textureSize(u_SSRTraceMap, 0) - ivec2(1);
	vec2 st = vec2(pix) / float(grid);
	ivec2 base = ivec2(floor(st));
	vec2 f = st - vec2(base);

	vec4 gi = vec4(0.0);
	float weightSum = 0.0;
	for (int i = 0; i < 4; i++)
	{
		ivec2 offset = ivec2(i & 1, i >> 1);
		ivec2 q = clamp(base + offset, ivec2(0), traceMax);
		ivec2 src = min(q * grid, fullSize - ivec2(1));

		float zs = texelFetch(u_SSRHiZMap, src, 0).r;
		vec3 Ns;
		if (!SSGIIsReceiver(src, zs, Ns))
			continue;

		float w = (offset.x == 1 ? f.x : 1.0 - f.x) * (offset.y == 1 ? f.y : 1.0 - f.y);
		w = max(w, 0.01);
		w *= exp(-abs(zs - z) / (0.02 * z + 1.0));
		w *= pow(max(dot(Ns, N), 0.0), 8.0);

		gi += w * texelFetch(u_SSRTraceMap, q, 0);
		weightSum += w;
	}

	return weightSum > 1.0e-6 ? gi / weightSum : vec4(0.0);
}

void main()
{
	ivec2 pix = ivec2(gl_FragCoord.xy);
	int mode = int(u_SSRSettings.z);
	bool linearScene = u_SSRSettings.w > 0.5;
	out_Color = vec4(0.0);

	float z = texelFetch(u_SSRHiZMap, pix, 0).r;
	vec3 N;
	if (!SSGIIsReceiver(pix, z, N))
	{
		if (mode != 0)
			out_Color = vec4(0.0, 0.0, 0.0, 1.0);
		return;
	}

	if (mode == 2)
	{
		vec3 source = texelFetch(u_SSGIRadianceMap, pix, 0).rgb;
		out_Color = vec4(linearScene ? source : SSGILinearToSRGB(source), 1.0);
		return;
	}

	vec4 gi = UpsampleGI(pix, z, N);
	vec3 albedo = SSGISRGBToLinear(texelFetch(u_SSGIAlbedoMap, pix, 0).rgb);
	vec3 indirect = albedo * max(gi.rgb, vec3(0.0)) * u_SSRSettings.x;

	if (mode == 1 || mode == 3)
	{
		vec3 value = mode == 1 ? max(gi.rgb, vec3(0.0)) : indirect;
		out_Color = vec4(linearScene ? value : SSGILinearToSRGB(value), 1.0);
		return;
	}

	// r_ssgiCompare: left half without GI
	if (gl_FragCoord.x < u_SSRSettings.y)
		return;

	if (linearScene)
	{
		out_Color = vec4(indirect, 0.0);
	}
	else
	{
		vec3 color = texelFetch(u_SSRSceneMap, pix, 0).rgb;
		out_Color = vec4(max(SSGILinearToSRGB(SSGISRGBToLinear(color) + indirect) - color, vec3(0.0)), 0.0);
	}
}
