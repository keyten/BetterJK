/*[Vertex]*/
void main()
{
	vec2 position = vec2(2.0 * float(gl_VertexID & 2) - 1.0, 4.0 * float(gl_VertexID & 1) - 1.0);
	gl_Position = vec4(position, 0.0, 1.0);
}

/*[Fragment]*/
// SSGI temporal accumulation (tr_ssgi.cpp, r_ssgiTemporal, see ssr_common.glsl), at trace resolution.
//
// The receiver is reprojected into the previous frame with the velocity buffer of the depth prepass
// when there is one (moving NPCs, doors), else with the previous camera (u_SSRReproject). The four
// previous trace texels around it are validated one by one (depth: disocclusion, normal: another
// surface, not a receiver), so the history never bleeds across silhouettes. It is rejected entirely
// off screen and after a cut (u_SSRSettings.x = 0: map load, teleport, camera cut, FOV or resolution
// change, see RB_ScreenHistoryValid).
//
// The history is clamped to the YCoCg range of the current 3x3 neighborhood: it may not keep light
// that no current neighbor has (a saber that moved away, a light that went out). The weight grows with
// the accumulated length (1 - 1 / (n + 1), capped by r_ssgiHistoryWeight) and drops with motion and
// with how much the clamp had to change the history (quickly changing light).
//
// u_SSRTraceMap = GI of this frame, u_SSRHistoryMap / u_SSRHistoryGeomMap = previous frame.
// Output 0: accumulated GI (rgb, albedo free), confidence. Output 1: geometry for the next frame
// (view depth, octahedral world normal, accumulated length; -1 = not a receiver).
//
// u_SSRSettings: x = history valid, y = max history weight, z = velocity buffer valid, w = trace grid scale
// u_SSRTexelSize: xy = 1 / full resolution size, zw = 1 / trace size

out vec4 out_Color;
out vec4 out_Glow;

#define SSGI_MAX_HISTORY 32.0

vec3 RGBToYCoCg(vec3 c)
{
	return vec3(
		 0.25 * c.r + 0.5 * c.g + 0.25 * c.b,
		 0.5  * c.r             - 0.5  * c.b,
		-0.25 * c.r + 0.5 * c.g - 0.25 * c.b);
}

vec3 YCoCgToRGB(vec3 c)
{
	return vec3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z);
}

void main()
{
	ivec2 tpix = ivec2(gl_FragCoord.xy);
	float grid = u_SSRSettings.w;
	ivec2 fullSize = textureSize(u_SSRHiZMap, 0);
	ivec2 pix = min(tpix * int(grid), fullSize - ivec2(1));
	vec2 uv = (vec2(pix) + 0.5) * u_SSRTexelSize.xy;

	float z = texelFetch(u_SSRHiZMap, pix, 0).r;
	vec3 N;
	bool receiver = SSRInsideView(uv) && SSGIIsReceiver(pix, z, N);

	vec4 current = texelFetch(u_SSRTraceMap, tpix, 0);
	out_Color = current;
	out_Glow = receiver ? vec4(z, SSREncodeNormal(N), 1.0) : vec4(0.0, 0.5, 0.5, -1.0);
	if (!receiver || u_SSRSettings.x < 0.5)
		return;

	// range of the current frame around the texel
	ivec2 maxCoord = textureSize(u_SSRTraceMap, 0) - ivec2(1);
	vec4 lo = vec4(1.0e30);
	vec4 hi = vec4(-1.0e30);
	for (int y = -1; y <= 1; y++)
	{
		for (int x = -1; x <= 1; x++)
		{
			vec4 c = texelFetch(u_SSRTraceMap, clamp(tpix + ivec2(x, y), ivec2(0), maxCoord), 0);
			vec4 c2 = vec4(RGBToYCoCg(c.rgb), c.a);
			lo = min(lo, c2);
			hi = max(hi, c2);
		}
	}

	// previous frame position and the depth it would have there if static
	vec3 P = SSRViewPosition(uv, z);
	vec4 prevClip = u_SSRReproject * vec4(P, 1.0);
	if (prevClip.w <= 0.0)
		return;
	vec2 prevUV = u_SSRViewport.xy + (prevClip.xy / prevClip.w * 0.5 + 0.5) * u_SSRViewport.zw;
	float tolerance = 0.03 * z + 2.0;

	if (u_SSRSettings.z > 0.5)
	{
		vec2 objectUV = uv - texture(u_VelocityMap, uv).rg;
		// a moving surface: the static depth prediction does not hold
		if (length((objectUV - prevUV) / u_SSRTexelSize.xy) > 1.0)
			tolerance = 0.25 * z + 8.0;
		prevUV = objectUV;
	}

	if (!SSRInsideView(prevUV))
		return;

	// previous trace texels around the point (texel q holds full resolution pixel q * grid)
	vec2 prevTrace = (prevUV / u_SSRTexelSize.xy - 0.5) / grid;
	ivec2 base = ivec2(floor(prevTrace));
	vec2 f = prevTrace - vec2(base);

	vec4 history = vec4(0.0);
	float historyLength = 0.0;
	float weightSum = 0.0;
	for (int i = 0; i < 4; i++)
	{
		ivec2 offset = ivec2(i & 1, i >> 1);
		ivec2 q = clamp(base + offset, ivec2(0), maxCoord);
		float w = (offset.x == 1 ? f.x : 1.0 - f.x) * (offset.y == 1 ? f.y : 1.0 - f.y);

		vec4 prevGeom = texelFetch(u_SSRHistoryGeomMap, q, 0);
		if (prevGeom.w < 0.0)
			continue;
		if (abs(prevGeom.x - prevClip.w) > tolerance)
			continue;
		if (dot(SSRDecodeNormal(prevGeom.yz), N) < 0.9)
			continue;

		history += w * texelFetch(u_SSRHistoryMap, q, 0);
		historyLength += w * prevGeom.w;
		weightSum += w;
	}

	// disocclusion
	if (weightSum < 0.05)
		return;
	history /= weightSum;
	historyLength /= weightSum;

	vec4 historyClamped = clamp(vec4(RGBToYCoCg(history.rgb), history.a), lo, hi);
	float before = RGBToYCoCg(history.rgb).x;
	float change = abs(before - historyClamped.x) / max(before + historyClamped.x, 1.0e-4);
	history = vec4(YCoCgToRGB(historyClamped.rgb), historyClamped.a);

	historyLength = min(historyLength + 1.0, SSGI_MAX_HISTORY);
	float motion = length((uv - prevUV) / u_SSRTexelSize.xy);
	float weight = min(u_SSRSettings.y, 1.0 - 1.0 / (historyLength + 1.0));
	weight *= 1.0 - 0.5 * smoothstep(2.0, 24.0, motion);
	weight *= 1.0 - 0.75 * clamp(2.0 * change, 0.0, 1.0);

	out_Color = mix(current, history, weight);
	// quickly changing light restarts the accumulation
	out_Glow.w = change > 0.25 ? 1.0 : historyLength;
}
