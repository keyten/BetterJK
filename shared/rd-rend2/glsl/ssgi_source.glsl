/*[Vertex]*/
void main()
{
	vec2 position = vec2(2.0 * float(gl_VertexID & 2) - 1.0, 4.0 * float(gl_VertexID & 1) - 1.0);
	gl_Position = vec4(position, 0.0, 1.0);
}

/*[Fragment]*/
// SSGI source radiance (tr_ssgi.cpp, see ssr_common.glsl): what the GI rays pick up at their hit
// points, linear HDR, at half resolution (mips are generated afterwards for far / wide hits).
//
// Source 0/1 (dynamic + emissive / emissive only): the radiance attachment lightall wrote
// (u_SSGIRadianceMap), only where it belongs to the visible surface (stored view depth matches).
// Source 2 (full scene, experimental): the opaque scene color (u_SSRSceneMap, a copy of renderFbo
// color 0), decoded to linear on maps with the legacy display encoded scene buffer.
//
// Every texel averages the valid pixels of its 2x2 block. Sky, view model and pixels without data
// are 0: a ray that hits them gets no light.
//
// u_SSRSettings: x = 1 full scene source, y = 1 linear scene

out vec4 out_Color;

void main()
{
	ivec2 fullSize = textureSize(u_SSRHiZMap, 0);
	ivec2 base = ivec2(gl_FragCoord.xy) * 2;

	vec3 sum = vec3(0.0);
	float count = 0.0;
	for (int i = 0; i < 4; i++)
	{
		ivec2 pix = min(base + ivec2(i & 1, i >> 1), fullSize - ivec2(1));
		float z = texelFetch(u_SSRHiZMap, pix, 0).r;
		if (!SSRIsSurface(z))
			continue;

		vec3 radiance;
		if (u_SSRSettings.x > 0.5)
		{
			radiance = texelFetch(u_SSRSceneMap, pix, 0).rgb;
			radiance = u_SSRSettings.y > 0.5 ? max(radiance, vec3(0.0)) : SSGISRGBToLinear(radiance);
		}
		else
		{
			vec4 stored = texelFetch(u_SSGIRadianceMap, pix, 0);
			if (abs(stored.a - z) > 0.02 * z + 1.0)
				continue;
			radiance = max(stored.rgb, vec3(0.0));
		}

		sum += radiance;
		count += 1.0;
	}

	out_Color = count > 0.0 ? vec4(sum / count, count * 0.25) : vec4(0.0);
}
