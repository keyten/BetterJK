/*[Vertex]*/
void main()
{
	vec2 position = vec2(2.0 * float(gl_VertexID & 2) - 1.0, 4.0 * float(gl_VertexID & 1) - 1.0);
	gl_Position = vec4(position, 0.0, 1.0);
}

/*[Fragment]*/
// SSGI spatial denoise (tr_ssgi.cpp, r_ssgiDenoise, see ssr_common.glsl), at trace resolution.
//
// One pass of an edge-aware a-trous filter: 5x5 B3 spline taps, u_SSRSettings.x texels apart (1, 2,
// 4 over the passes). A tap only counts when it is a GI receiver on the same surface:
//   - plane distance of the tap to the receiver's tangent plane (not across silhouettes, not from
//     foreground to background), tolerance = the pixel footprint of the tap distance,
//   - normal similarity pow(dot, 16) (not from the floor onto the wall across a corner),
//   - after the first pass, luminance similarity (keeps contact detail).
//
// u_SSRTraceMap = input (GI, confidence).
// u_SSRSettings: x = tap spacing (trace texels), y = luminance weight (0 = off), z = trace grid scale
// u_SSRTexelSize: xy = 1 / full resolution size

out vec4 out_Color;

void main()
{
	ivec2 tpix = ivec2(gl_FragCoord.xy);
	float grid = u_SSRSettings.z;
	int spacing = int(u_SSRSettings.x);
	ivec2 fullSize = textureSize(u_SSRHiZMap, 0);
	ivec2 traceMax = textureSize(u_SSRTraceMap, 0) - ivec2(1);

	vec4 center = texelFetch(u_SSRTraceMap, tpix, 0);
	out_Color = center;

	ivec2 pix = min(tpix * int(grid), fullSize - ivec2(1));
	float z = texelFetch(u_SSRHiZMap, pix, 0).r;
	vec3 N;
	if (!SSGIIsReceiver(pix, z, N))
		return;

	vec3 P = SSRViewPosition((vec2(pix) + 0.5) * u_SSRTexelSize.xy, z);
	vec3 viewN = normalize(mat3(u_SSRWorldToView) * N);
	float tolerance = 0.5 + 2.0 * float(spacing) * grid * z * u_SSRDepthParams.w;
	float centerLuma = SSRLuma(center.rgb);

	const float kernel[3] = float[3](0.375, 0.25, 0.0625);

	vec4 sum = vec4(0.0);
	float weightSum = 0.0;
	for (int y = -2; y <= 2; y++)
	{
		for (int x = -2; x <= 2; x++)
		{
			ivec2 q = tpix + ivec2(x, y) * spacing;
			if (any(lessThan(q, ivec2(0))) || any(greaterThan(q, traceMax)))
				continue;

			ivec2 qpix = min(q * int(grid), fullSize - ivec2(1));
			float zq = texelFetch(u_SSRHiZMap, qpix, 0).r;
			vec3 Nq;
			if (!SSGIIsReceiver(qpix, zq, Nq))
				continue;

			vec4 tap = texelFetch(u_SSRTraceMap, q, 0);
			vec3 Pq = SSRViewPosition((vec2(qpix) + 0.5) * u_SSRTexelSize.xy, zq);

			float w = kernel[abs(x)] * kernel[abs(y)];
			w *= exp(-abs(dot(viewN, Pq - P)) / tolerance);
			w *= pow(max(dot(N, Nq), 0.0), 16.0);
			if (u_SSRSettings.y > 0.0)
			{
				float l = SSRLuma(tap.rgb);
				w *= exp(-u_SSRSettings.y * abs(l - centerLuma) / (0.5 * (l + centerLuma) + 0.01));
			}

			sum += w * tap;
			weightSum += w;
		}
	}

	if (weightSum > 1.0e-6)
		out_Color = sum / weightSum;
}
