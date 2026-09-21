/*[Vertex]*/
void main()
{
	vec2 position = vec2(2.0 * float(gl_VertexID & 2) - 1.0, 4.0 * float(gl_VertexID & 1) - 1.0);
	gl_Position = vec4(position, 0.0, 1.0);
}

/*[Fragment]*/
// Full resolution screen-space lighting composite, sampled by lightall
// (u_SSAOMap) during the main pass of the same view:
//
//   r = ambient occlusion: legacy SSAO (bilinear, as lightall sampled it
//       before), GTAO (depth-aware upsampled when rendered at half
//       resolution), or a split screen of both
//   g = short range contact shadow of the primary (sun) light, multiplied
//       into the sun shadow map visibility by lightall
//
// Contact shadows march a short ray from the receiver towards the sun through
// the depth buffer. A sample is a hit when the ray is behind the depth buffer
// by less than the assumed occluder thickness; farther behind means the ray
// passes behind a foreground object (discontinuity), not through an occluder.

#define DEPTH_HACK_MAX 0.3001

uniform sampler2D u_ScreenDepthMap; // hardware depth, full resolution
uniform sampler2D u_AODepthMap;     // GTAO linear depth (AO resolution)
uniform sampler2D u_AOMap;          // GTAO result: r = visibility, gba = normal
uniform sampler2D u_LegacyAOMap;    // legacy SSAO, half resolution

uniform vec4 u_AOProjection;        // P[0], P[5], P[8], P[9]
uniform vec4 u_AODepthParams;       // P[14], P[10], zFar, sky threshold
uniform vec4 u_AOViewport;          // view rectangle in texture coordinates
uniform vec4 u_AOTexelSize;         // xy = 1 / AO texture size, zw = 1 / screen size
uniform vec4 u_AOSettings;          // AO source (0 none, 1 legacy, 2 GTAO, 3 split), split x, contact shadows, contact strength
uniform vec4 u_AOSettings2;         // contact length, steps, thickness, view size of a pixel at depth 1
uniform vec3 u_AOLightDir;          // view space direction to the sun

out vec4 out_Color;

float LinearDepth(float d)
{
	if (d <= DEPTH_HACK_MAX)
		return -1.0;
	return u_AODepthParams.x / (2.0 * d - 1.0 + u_AODepthParams.y);
}

vec3 ViewPosition(vec2 uv, float z)
{
	vec2 ndc = (uv - u_AOViewport.xy) / u_AOViewport.zw * 2.0 - 1.0;
	return vec3((ndc + u_AOProjection.zw) * z / u_AOProjection.xy, z);
}

vec2 ProjectToUV(vec3 p)
{
	vec2 ndc = p.xy * u_AOProjection.xy / p.z - u_AOProjection.zw;
	return (ndc * 0.5 + 0.5) * u_AOViewport.zw + u_AOViewport.xy;
}

float Bayer4(ivec2 p)
{
	p &= 3;
	int b = ((p.x ^ p.y) & 1) * 8 + (p.y & 1) * 4 + ((p.x ^ p.y) & 2) + ((p.y & 2) >> 1);
	return float(b);
}

// Depth-aware upsampling of the GTAO result: the 2x2 bilinear footprint,
// each texel weighted by how well its tangent plane (depth + normal) predicts
// this pixel's position. Falls back to the best matching texel on edges.
float UpsampleGTAO(vec2 uv, vec3 P, float z)
{
	vec2 aoSize = 1.0 / u_AOTexelSize.xy;
	vec2 st = uv * aoSize - 0.5;
	ivec2 base = ivec2(floor(st));
	vec2 f = st - vec2(base);
	ivec2 maxCoord = ivec2(aoSize) - ivec2(1);

	float tolerance = 0.5 + z * 0.01;
	float sum = 0.0;
	float sumW = 0.0;
	float best = 1.0;
	float bestDist = 1e30;
	for (int i = 0; i < 4; i++)
	{
		ivec2 o = ivec2(i & 1, i >> 1);
		ivec2 p = clamp(base + o, ivec2(0), maxCoord);
		float zs = texelFetch(u_AODepthMap, p, 0).r;
		if (zs < 0.0 || zs >= u_AODepthParams.w)
			continue;

		vec4 s = texelFetch(u_AOMap, p, 0);
		vec3 Ps = ViewPosition((vec2(p) + 0.5) * u_AOTexelSize.xy, zs);
		vec3 Ns = normalize(s.gba * 2.0 - 1.0);
		float planeDist = abs(dot(Ns, P - Ps)) + 0.25 * abs(zs - z);

		vec2 bw = mix(vec2(1.0) - f, f, vec2(o));
		float d = planeDist / tolerance;
		float w = bw.x * bw.y / (1.0 + d * d * 16.0);
		sum += s.r * w;
		sumW += w;

		if (planeDist < bestDist)
		{
			bestDist = planeDist;
			best = s.r;
		}
	}

	return sumW > 1e-3 ? sum / sumW : best;
}

float ContactShadow(ivec2 pix, vec2 uv, vec3 P, float z)
{
	vec3 L = u_AOLightDir;
	float rayLength = u_AOSettings2.x;
	int steps = int(u_AOSettings2.y);
	float pixelSize = z * u_AOSettings2.w;

	// start slightly off the receiver, scaled with the pixel footprint to stay
	// clear of depth quantization (self-shadow acne)
	vec3 origin = P + L * (pixelSize * 1.5 + 0.1);
	float stepLength = rayLength / float(steps);
	float jitter = (Bayer4(pix) + 0.5) / 16.0;

	vec2 screenSize = 1.0 / u_AOTexelSize.zw;
	vec2 viewportMin = u_AOViewport.xy;
	vec2 viewportMax = u_AOViewport.xy + u_AOViewport.zw;

	float occlusion = 0.0;
	for (int i = 0; i < steps; i++)
	{
		float t = (float(i) + jitter) * stepLength;
		vec3 Q = origin + L * t;
		if (Q.z <= 1.0)
			break; // behind the camera

		vec2 quv = ProjectToUV(Q);
		if (any(lessThan(quv, viewportMin)) || any(greaterThanEqual(quv, viewportMax)))
			break; // occluders off screen are unknown

		float sceneZ = LinearDepth(texelFetch(u_ScreenDepthMap, ivec2(quv * screenSize), 0).r);
		if (sceneZ < 0.0)
			continue;

		float behind = Q.z - sceneZ;
		float samplePixelSize = Q.z * u_AOSettings2.w;
		float bias = samplePixelSize * 1.5 + 0.05;
		float thickness = u_AOSettings2.z + samplePixelSize * 2.0;
		if (behind > bias && behind < thickness)
		{
			// fade out towards the end of the ray, the first hit is the strongest
			occlusion = 1.0 - smoothstep(0.5, 1.0, t / rayLength);
			break;
		}
	}

	// fade near the screen edges, where occluders start to be missing
	vec2 edge = min(uv - viewportMin, viewportMax - uv) / u_AOViewport.zw;
	occlusion *= clamp(min(edge.x, edge.y) * 20.0, 0.0, 1.0);

	return 1.0 - occlusion * u_AOSettings.w;
}

void main()
{
	ivec2 pix = ivec2(gl_FragCoord.xy);
	vec2 uv = gl_FragCoord.xy * u_AOTexelSize.zw;
	float z = LinearDepth(texelFetch(u_ScreenDepthMap, pix, 0).r);

	if (z < 0.0 || z >= u_AODepthParams.w)
	{
		// sky, far plane, depth hack: legacy AO kept as lightall saw it before
		float legacy = u_AOSettings.x == 1.0 ? texture(u_LegacyAOMap, uv).r : 1.0;
		out_Color = vec4(legacy, 1.0, 0.0, 1.0);
		return;
	}

	vec3 P = ViewPosition(uv, z);

	float ao = 1.0;
	int source = int(u_AOSettings.x);
	if (source == 3)
		source = uv.x < u_AOSettings.y ? 1 : 2;
	if (source == 1)
		ao = texture(u_LegacyAOMap, uv).r;
	else if (source == 2)
		ao = UpsampleGTAO(uv, P, z);

	float contact = 1.0;
	if (u_AOSettings.z > 0.5)
		contact = ContactShadow(pix, uv, P, z);

	out_Color = vec4(ao, contact, 0.0, 1.0);
}
