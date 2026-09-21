/*[Vertex]*/
void main()
{
	vec2 position = vec2(2.0 * float(gl_VertexID & 2) - 1.0, 4.0 * float(gl_VertexID & 1) - 1.0);
	gl_Position = vec4(position, 0.0, 1.0);
}

/*[Fragment]*/
// SSR depth pyramid (tr_ssr.cpp, see ssr_common.glsl).
//
// LINEARIZE: hardware depth (u_ScreenDepthMap) -> positive linear view depth, mip 0.
// Otherwise: the next mip, closest depth of the 2x2 source texels (plus the extra row/column of odd
// sizes, so a coarse texel never misses a surface below it). View model texels are ignored: their
// depth is meaningless for the reflected rays. u_SSRHiZMap has BASE_LEVEL = the source level.

out vec4 out_Color;

void main()
{
	ivec2 pix = ivec2(gl_FragCoord.xy);

#if defined(LINEARIZE)
	float d = texelFetch(u_ScreenDepthMap, pix, 0).r;
	float z;
	if (d <= SSR_DEPTH_HACK_MAX)
		z = SSR_DEPTH_VIEWMODEL;
	else if (d >= 1.0)
		z = SSR_DEPTH_SKY;
	else
		z = u_SSRDepthParams.x / (2.0 * d - 1.0 + u_SSRDepthParams.y);
	out_Color = vec4(z);
#else
	ivec2 srcSize = textureSize(u_SSRHiZMap, 0);
	ivec2 maxCoord = srcSize - ivec2(1);
	ivec2 src = pix * 2;

	// odd source sizes: the last destination texel also covers the extra row/column
	ivec2 dstSize = max(srcSize / 2, ivec2(1));
	ivec2 extent = ivec2(2);
	if (pix.x == dstSize.x - 1 && (srcSize.x & 1) != 0)
		extent.x = 3;
	if (pix.y == dstSize.y - 1 && (srcSize.y & 1) != 0)
		extent.y = 3;

	float closest = SSR_DEPTH_SKY;
	for (int y = 0; y < 3; y++)
	{
		if (y >= extent.y)
			break;
		for (int x = 0; x < 3; x++)
		{
			if (x >= extent.x)
				break;
			float z = texelFetch(u_SSRHiZMap, min(src + ivec2(x, y), maxCoord), 0).r;
			if (z > 0.0)
				closest = min(closest, z);
		}
	}
	out_Color = vec4(closest);
#endif
}
