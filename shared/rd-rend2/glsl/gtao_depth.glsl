/*[Vertex]*/
void main()
{
	vec2 position = vec2(2.0 * float(gl_VertexID & 2) - 1.0, 4.0 * float(gl_VertexID & 1) - 1.0);
	gl_Position = vec4(position, 0.0, 1.0);
}

/*[Fragment]*/
// GTAO depth prefilter.
//
// LINEARIZE: converts the depth buffer into positive linear view depth (the
// input of all other screen-space AO passes). At half resolution every output
// texel takes one of its 2x2 source depths, the closest and the farthest one
// in a checkerboard pattern, so both sides of a silhouette stay represented
// for the depth-aware upsampling.
//
// Otherwise: builds the next mip of the linear depth chain. The mip filter is
// a weighted average that prefers the farthest depth (idea from XeGTAO's
// depth MIP filter, see gtao.glsl), so thin foreground occluders fade out of
// the coarse mips instead of spreading into dark halos.
//
// Depth values <= DEPTH_HACK_MAX come from RF_DEPTHHACK surfaces (first person
// weapon, drawn with glDepthRange(0, 0.3)); their depth is meaningless for
// reconstruction so they are marked with a negative depth: no AO, no occluder.

#define DEPTH_HACK_MAX 0.3001

#if defined(LINEARIZE)
uniform sampler2D u_ScreenDepthMap; // hardware depth, full resolution
#else
uniform sampler2D u_AODepthMap;     // previous mip, BASE_LEVEL = source level
#endif

uniform vec4 u_AODepthParams; // P[14], P[10], zFar, sky threshold
uniform vec4 u_AOSettings;    // LINEARIZE: x = half resolution; else: x = effect radius, y = falloff range

out vec4 out_Color;

#if defined(LINEARIZE)
float LinearDepth(float d)
{
	if (d <= DEPTH_HACK_MAX)
		return -1.0;
	return u_AODepthParams.x / (2.0 * d - 1.0 + u_AODepthParams.y);
}
#endif

void main()
{
	ivec2 pix = ivec2(gl_FragCoord.xy);

#if defined(LINEARIZE)
	if (u_AOSettings.x < 0.5)
	{
		out_Color = vec4(LinearDepth(texelFetch(u_ScreenDepthMap, pix, 0).r));
		return;
	}

	ivec2 maxCoord = textureSize(u_ScreenDepthMap, 0) - ivec2(1);
	ivec2 src = pix * 2;
	vec4 d = vec4(
		texelFetch(u_ScreenDepthMap, min(src,               maxCoord), 0).r,
		texelFetch(u_ScreenDepthMap, min(src + ivec2(1, 0), maxCoord), 0).r,
		texelFetch(u_ScreenDepthMap, min(src + ivec2(0, 1), maxCoord), 0).r,
		texelFetch(u_ScreenDepthMap, min(src + ivec2(1, 1), maxCoord), 0).r);

	// depth is monotonic in view distance: select in hardware depth
	float closest  = min(min(d.x, d.y), min(d.z, d.w));
	float farthest = max(max(d.x, d.y), max(d.z, d.w));
	bool checker = ((pix.x + pix.y) & 1) != 0;
	out_Color = vec4(LinearDepth(checker ? farthest : closest));
#else
	ivec2 maxCoord = textureSize(u_AODepthMap, 0) - ivec2(1);
	ivec2 src = pix * 2;
	vec4 z = vec4(
		texelFetch(u_AODepthMap, min(src,               maxCoord), 0).r,
		texelFetch(u_AODepthMap, min(src + ivec2(1, 0), maxCoord), 0).r,
		texelFetch(u_AODepthMap, min(src + ivec2(0, 1), maxCoord), 0).r,
		texelFetch(u_AODepthMap, min(src + ivec2(1, 1), maxCoord), 0).r);

	float farthest = max(max(z.x, z.y), max(z.z, z.w));
	if (farthest < 0.0)
	{
		out_Color = vec4(-1.0);
		return;
	}

	// depths within (radius - falloff) of the farthest one get full weight,
	// fading to zero at the effect radius; invalid (negative) depths none
	float falloffRange = max(u_AOSettings.y, 1e-3);
	float falloffFrom = u_AOSettings.x - falloffRange;
	vec4 w = clamp((falloffFrom - (farthest - z)) / falloffRange + 1.0, 0.0, 1.0);
	w *= step(0.0, z);
	float sumW = dot(w, vec4(1.0));
	out_Color = vec4(sumW > 1e-4 ? dot(w, z) / sumW : farthest);
#endif
}
