/*[Vertex]*/
void main()
{
	vec2 position = vec2(2.0 * float(gl_VertexID & 2) - 1.0, 4.0 * float(gl_VertexID & 1) - 1.0);
	gl_Position = vec4(position, 0.0, 1.0);
}

/*[Fragment]*/
// r_ssgiDebug 1, 2, 5, 10 (tr_ssgi.cpp, see ssr_common.glsl), drawn over the final image. Pixels that
// do not receive GI are black, except in the hit mask (dark gray).
//
//   1 ray hit mask (green, brighter = more rays hit) / all rays missed (red)
//   2 mean hit distance (blue near .. red at r_ssgiMaxDistance)
//   5 temporal history weight (from the accumulated length; black = rejected / no history)
//   10 receiver diffuse albedo (after the metalness split)
//
// u_SSRTraceMap = hit info of the trace (x = distance / max, y = hit fraction), u_SSRHistoryGeomMap =
// history geometry of this frame (w = accumulated length, < 0 = none)
// u_SSRSettings: x = debug view, y = trace grid scale, z = r_ssgiHistoryWeight, w = 1 temporal on

out vec4 out_Color;

void main()
{
	ivec2 pix = ivec2(gl_FragCoord.xy);
	int view = int(u_SSRSettings.x);
	ivec2 tpix = pix / int(u_SSRSettings.y);

	float z = texelFetch(u_SSRHiZMap, pix, 0).r;
	vec3 N;
	vec3 color = vec3(0.0);

	if (SSGIIsReceiver(pix, z, N))
	{
		vec4 hit = texelFetch(u_SSRTraceMap, tpix, 0);
		if (view == 1)
		{
			color = hit.y > 0.0 ? vec3(0.1, 0.3 + 0.7 * hit.y, 0.1) : vec3(0.6, 0.05, 0.05);
		}
		else if (view == 2)
		{
			if (hit.y > 0.0)
				color = vec3(hit.x, 1.0 - abs(2.0 * hit.x - 1.0), 1.0 - hit.x);
		}
		else if (view == 5)
		{
			if (u_SSRSettings.w > 0.5)
			{
				float n = texelFetch(u_SSRHistoryGeomMap, tpix, 0).w;
				if (n > 0.0)
					color = vec3(min(u_SSRSettings.z, 1.0 - 1.0 / (n + 1.0)));
			}
		}
		else
		{
			color = texelFetch(u_SSGIAlbedoMap, pix, 0).rgb;
		}
	}
	else if (view == 1)
	{
		color = vec3(0.04);
	}

	out_Color = vec4(color, 1.0);
}
