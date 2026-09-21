/*[Vertex]*/
void main()
{
	vec2 position = vec2(2.0 * float(gl_VertexID & 2) - 1.0, 4.0 * float(gl_VertexID & 1) - 1.0);
	gl_Position = vec4(position, 0.0, 1.0);
}

/*[Fragment]*/
// SSR composite (tr_ssr.cpp, see ssr_common.glsl), drawn additively into color 0 of renderFbo after
// the opaque surfaces.
//
// lightall already added the cubemap reflection C = cubemap radiance * W. Where the SSR confidence is
// c, a part of it is replaced by the screen-space radiance under the same BRDF weight W:
//
//   color += c * (SSR radiance * W - C)
//
// (the SSR input is premultiplied by c). c = 1 shows the SSR instead of the cubemap reflection, c = 0
// leaves the pixel as lightall wrote it: the cubemap reflection is never doubled.
//
// u_SSRTraceMap = final SSR (resolve or temporal accumulation).
// u_SSRSettings: x = strength (confidence scale), y = split x in window pixels (r_ssrCompare, pixels
// left of it keep the cubemap reflection, -1 = off), z = debug view 7..10 (0 = off), w = pass:
// 0 = signed delta (float target), 1 = replaced cubemap part (subtracted), 2 = SSR part (added)

out vec4 out_Color;

void main()
{
	if (gl_FragCoord.x < u_SSRSettings.y)
		discard;

	ivec2 pix = ivec2(gl_FragCoord.xy);
	vec4 ssr = texelFetch(u_SSRTraceMap, pix, 0);
	vec3 weight = SSRSpecularWeight(pix);
	vec3 cubemap = texelFetch(u_SSRCubemapMap, pix, 0).rgb;

	float strength = u_SSRSettings.x;
	vec3 ssrPart = ssr.rgb * weight * strength;
	vec3 cubemapPart = cubemap * (ssr.a * strength);

	int debugView = int(u_SSRSettings.z);
	if (debugView != 0)
	{
		// the reflection terms alone, through the normal tone mapping
		float z = texelFetch(u_SSRHiZMap, pix, 0).r;
		vec4 normalRoughness;
		vec3 result = vec3(0.0);
		if (SSRIsReceiver(pix, z, normalRoughness))
		{
			if (debugView == 7)      // raw SSR radiance
				result = ssr.a > 0.0 ? ssr.rgb / ssr.a : vec3(0.0);
			else if (debugView == 8) // cubemap reflection
				result = cubemap;
			else if (debugView == 9) // final hybrid reflection
				result = cubemap + ssrPart - cubemapPart;
			else                     // replaced part
				result = abs(ssrPart - cubemapPart);
		}
		out_Color = vec4(result, 1.0);
		return;
	}

	int pass = int(u_SSRSettings.w);
	if (pass == 1)
		out_Color = vec4(cubemapPart, 0.0);
	else if (pass == 2)
		out_Color = vec4(ssrPart, 0.0);
	else
		out_Color = vec4(ssrPart - cubemapPart, 0.0);
}
