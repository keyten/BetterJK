/*[Vertex]*/
void main()
{
	vec2 position = vec2(2.0 * float(gl_VertexID & 2) - 1.0, 4.0 * float(gl_VertexID & 1) - 1.0);
	gl_Position = vec4(position, 0.0, 1.0);
}

/*[Fragment]*/
// GTAO spatial denoiser: one edge-aware 3x3 pass with a variable tap distance
// (1, 2, 4... for successive passes, a-trous style). Two passes cover the
// 4x4 noise pattern of the main pass.
//
// Weights: binomial kernel * plane distance (the neighbour's position against
// the center's tangent plane, so sloped surfaces blur fully while steps and
// silhouettes do not) * normal similarity. Sky and depth hack texels are
// never used.
//
// Input/output: r = visibility, gba = view space normal * 0.5 + 0.5

uniform sampler2D u_AOMap;       // previous GTAO result
uniform sampler2D u_AODepthMap;  // linear view depth, same resolution

uniform vec4 u_AOProjection;     // P[0], P[5], P[8], P[9]
uniform vec4 u_AODepthParams;    // P[14], P[10], zFar, sky threshold
uniform vec4 u_AOViewport;       // view rectangle in texture coordinates
uniform vec4 u_AOTexelSize;      // 1 / AO texture size (xy)
uniform vec4 u_AOSettings;       // x = tap distance in texels

out vec4 out_Color;

vec3 ViewPosition(vec2 uv, float z)
{
	vec2 ndc = (uv - u_AOViewport.xy) / u_AOViewport.zw * 2.0 - 1.0;
	return vec3((ndc + u_AOProjection.zw) * z / u_AOProjection.xy, z);
}

void main()
{
	ivec2 pix = ivec2(gl_FragCoord.xy);
	vec4 center = texelFetch(u_AOMap, pix, 0);
	float z = texelFetch(u_AODepthMap, pix, 0).r;

	if (z < 0.0 || z >= u_AODepthParams.w)
	{
		out_Color = center;
		return;
	}

	ivec2 maxCoord = textureSize(u_AOMap, 0) - ivec2(1);
	int stride = int(u_AOSettings.x);
	vec3 P = ViewPosition((vec2(pix) + 0.5) * u_AOTexelSize.xy, z);
	vec3 N = normalize(center.gba * 2.0 - 1.0);

	// tolerated distance from the tangent plane grows with the pixel footprint
	float planeTolerance = 0.5 + z * 0.01 * float(stride);

	float sum = 0.0;
	float sumW = 0.0;
	for (int y = -1; y <= 1; y++)
	{
		for (int x = -1; x <= 1; x++)
		{
			ivec2 p = pix + ivec2(x, y) * stride;
			if (any(lessThan(p, ivec2(0))) || any(greaterThan(p, maxCoord)))
				continue;

			float zs = texelFetch(u_AODepthMap, p, 0).r;
			if (zs < 0.0 || zs >= u_AODepthParams.w)
				continue;

			vec4 s = texelFetch(u_AOMap, p, 0);
			vec3 Ps = ViewPosition((vec2(p) + 0.5) * u_AOTexelSize.xy, zs);
			vec3 Ns = normalize(s.gba * 2.0 - 1.0);

			float planeDist = abs(dot(N, Ps - P)) / planeTolerance;
			float w = (x == 0 ? 2.0 : 1.0) * (y == 0 ? 2.0 : 1.0);
			w *= 1.0 / (1.0 + planeDist * planeDist);
			w *= pow(clamp(dot(N, Ns), 0.0, 1.0), 8.0);

			sum += s.r * w;
			sumW += w;
		}
	}

	out_Color = vec4(sumW > 1e-4 ? sum / sumW : center.r, center.gba);
}
