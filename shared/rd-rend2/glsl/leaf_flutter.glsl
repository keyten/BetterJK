/*[Vertex]*/
// MD3 leaf flutter (r_leafFlutter, tr_leafflutter.cpp). Pasted into the vertex
// shader of lightall, generic, fogpass and velocity, so every pass of a
// FOLIAGE_LEAF surface (main, depth prepass, sun / point shadows, fog, motion
// vectors) moves the vertices exactly the same way.
//
// Only a small, zero mean, spatially coherent displacement of the leaf card
// vertices: the tree itself never bends and non leaf surfaces never get here
// (u_LeafFlutter.z == 0 for them, a uniform branch). Pure function of the rest
// world position, the entity origin (per tree phase) and time; no camera input.

uniform vec4 u_LeafFlutter;			// wind dir x, y (unit), amplitude in units (0 = off), speed
uniform vec4 u_LeafFlutterParams;	// time, previous frame time, 1 / model xy radius, normal amount
uniform float u_LeafFlutterDebug;	// fragment debug view: 0, 4 = highlight, 8 = magnitude

bool LeafFlutterEnabled()
{
	return u_LeafFlutter.z > 0.0;
}

// Stable per tree phase in [0, 1) from the entity origin, on an 8 unit lattice
// so float noise in the model matrix can't change it.
float LeafFlutterSeed(in vec3 entityOrigin)
{
	ivec2 c = ivec2(floor(entityOrigin.xy * 0.125));
	uint h = uint(c.x) * 73856093u ^ uint(c.y) * 19349663u;
	h = (h ^ (h >> 13u)) * 1274126177u;
	h ^= h >> 16u;
	return float(h & 0xffffu) * (1.0 / 65536.0);
}

// 0 at the trunk axis, 1 towards the crown edge (object space, so the scale of
// the entity doesn't matter): vertices where the cards meet the trunk and the
// branches stay in place, the outer card corners move.
float LeafFlutterWeight(in vec3 objectPosition)
{
	return smoothstep(0.08, 0.45, length(objectPosition.xy) * u_LeafFlutterParams.z);
}

// World space displacement at the rest world position p. Two bands:
//   slow: ~600 unit wavelength, card scale drift of the whole card
//   fast: ~130 unit wavelength, the corners of one card go slightly out of step
// Both are continuous in p, so vertices shared by two triangles get the same
// offset (no tearing) and neighbouring trees differ by position and seed.
// |offset| <= 0.81 * amplitude * weight. bands = (slow, fast) in [-1, 1].
vec3 LeafFlutterOffset(in vec3 p, in float seed, in float t, in float weight, out vec2 bands)
{
	vec2 dir = u_LeafFlutter.xy;
	vec2 side = vec2(-dir.y, dir.x);
	float tw = t * u_LeafFlutter.w * (0.9 + 0.2 * seed);

	float slow = 0.6 * sin(tw * 1.7 + dot(p.xy, dir) * 0.010 + seed * 6.2832)
	           + 0.4 * sin(tw * 1.1 + dot(p.xy, side) * 0.013 + seed * 3.1);
	float fast = sin(tw * 5.3 + dot(p, vec3(0.041, 0.037, 0.053)) + seed * 11.0)
	           * (0.6 + 0.4 * sin(tw * 2.3 + p.z * 0.02));
	bands = vec2(slow, fast);

	float amplitude = u_LeafFlutter.z * weight;
	return vec3(dir * (0.6 * slow) + side * (0.45 * fast), 0.3 * fast) * amplitude;
}

// Small tilt of the world space normal in step with the displacement. On the
// per pixel lit stock leaves (rgbGen lightingDiffuse) this shimmers the
// lighting with no extra silhouette motion. Normal amount 0 = unchanged.
vec3 LeafFlutterNormal(in vec3 normal, in vec2 bands, in float weight)
{
	vec2 dir = u_LeafFlutter.xy;
	vec2 side = vec2(-dir.y, dir.x);
	vec3 tilt = vec3(side * bands.y + dir * (0.5 * bands.x), 0.0);
	return normalize(normal + tilt * (u_LeafFlutterParams.w * weight));
}

// Debug magnitude in [0, 1]: |offset| relative to the largest possible offset
float LeafFlutterMagnitude(in vec3 offset)
{
	return clamp(length(offset) / (0.81 * u_LeafFlutter.z), 0.0, 1.0);
}
