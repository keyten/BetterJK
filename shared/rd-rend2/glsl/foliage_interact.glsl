/*[Vertex]*/
// Foliage character interaction (r_foliageInteraction, tr_foliageinteract.cpp).
// Pasted into the vertex shader of surface_sprites (grass) and, with
// plant_bend.glsl, lightall, generic, fogpass and velocity (MD3 plants), so
// every pass (main, depth prepass, sun / point shadows, fog, motion vectors)
// bends a plant the same way.
//
// Stateless: a pure function of the rest position and the colliders of this
// frame (and of the previous frame, for motion vectors). The colliders are the
// real character bodies sent by cgame, never the camera.

#define FOLIAGE_MAX_INTERACTORS 16

// std140, FoliageInteractionBlock in tr_local.h. Per collider two vec4:
//   [2i]     axis x, y, bottom z (feet), top z
//   [2i + 1] radius, velocity x, velocity y, unused
layout(std140) uniform FoliageInteraction
{
	vec4 u_FIParams;	// current count, previous count, strength, debug: 1 = no wind
	vec4 u_FICurrent[FOLIAGE_MAX_INTERACTORS * 2];
	vec4 u_FIPrevious[FOLIAGE_MAX_INTERACTORS * 2];
};

// the largest angle a stem turns away from its rest direction (65 degrees):
// a character can flatten a plant but never fold it over its root
const float FOLIAGE_MAX_BEND_COS = 0.42261826;
const float FOLIAGE_MAX_BEND_SIN = 0.90630779;

// r_foliageInteractionDebug 4: interaction only, the wind stays at rest
bool FoliageInteractionNoWind()
{
	return u_FIParams.w > 0.5;
}

// Horizontal bend vector the colliders push the reference point q with: tip
// displacement per unit of stem length, before FoliageApplyBend limits it.
// Contact (distance to the capsule) is the main term, so a character standing
// still keeps the plant parted; velocity only biases the direction and adds a
// little push along the walk. heat = strongest contact in [0, 1].
vec2 FoliageInteractionBend(in vec3 q, in bool previous, out float heat)
{
	vec2 bend = vec2(0.0);
	heat = 0.0;
	int count = int(previous ? u_FIParams.y : u_FIParams.x);

	for (int i = 0; i < FOLIAGE_MAX_INTERACTORS; ++i)
	{
		if (i >= count)
			break;

		vec4 axis = previous ? u_FIPrevious[2 * i] : u_FICurrent[2 * i];
		vec4 body = previous ? u_FIPrevious[2 * i + 1] : u_FICurrent[2 * i + 1];
		float radius = body.x;
		float reach = radius * 1.75;

		vec2 d = q.xy - axis.xy;
		float d2 = dot(d, d);
		if (d2 >= reach * reach)
			continue;

		// capsule: vertical segment with round ends at the feet and the head,
		// so the lower legs reach the grass and a jump lifts the contact off
		float z0 = axis.z + radius;
		float z1 = max(axis.w - radius, z0);
		float dz = q.z - clamp(q.z, z0, z1);
		float dist = sqrt(d2 + dz * dz);
		float contact = 1.0 - smoothstep(0.6 * radius, reach, dist);
		if (contact <= 0.0)
			continue;

		vec2 velocity = body.yz;
		float speed = length(velocity);
		vec2 moveDir = speed > 1.0 ? velocity / speed : vec2(0.0);
		float len = sqrt(d2);
		vec2 n;
		if (len > 0.5)
			n = d / len;
		else if (speed > 1.0)
			n = moveDir;	// right on the axis: push along the walk
		else
		{
			float a = fract(sin(dot(q.xy, vec2(12.9898, 78.233))) * 43758.547) * 6.2832;
			n = vec2(cos(a), sin(a));
		}

		// walking through: bias along the movement, a bit more in front of
		// the body (|n + 0.6 s moveDir| >= 0.4, normalize is safe)
		float s = clamp(speed * (1.0 / 320.0), 0.0, 1.0);
		vec2 dir = normalize(n + (0.6 * s) * moveDir);
		float magnitude = contact * (1.0 + 0.35 * s * max(dot(n, moveDir), 0.0));

		bend += dir * magnitude;
		heat = max(heat, contact);
	}

	return bend * u_FIParams.z;
}

// Bends the stem vector v (vertex - root) by the horizontal bend vector,
// scaled by weight (0 at the root, 1 at the tip). The length is kept (no
// stretching) and the turn is limited to 65 degrees, so no push can fold a
// plant over, whatever direction the stem had.
vec3 FoliageApplyBend(in vec3 v, in vec2 bend, in float weight)
{
	float len = length(v);
	vec2 b = bend * weight;
	if (len < 1e-3 || dot(b, b) < 1e-8)
		return v;

	vec3 nv = v / len;
	vec3 bent = normalize(nv + vec3(b, 0.0));
	float c = dot(nv, bent);
	if (c < FOLIAGE_MAX_BEND_COS)
	{
		vec3 side = bent - nv * c;
		float sideLen = length(side);
		// antiparallel: nothing sensible to turn towards, keep the rest pose
		if (sideLen < 1e-4)
			return v;
		bent = nv * FOLIAGE_MAX_BEND_COS + side * (FOLIAGE_MAX_BEND_SIN / sideLen);
	}
	return bent * len;
}

// Turns a normal (or tangent) with the rotation that took rest to bent
// (both stem vectors of the same length): Rodrigues around rest x bent.
vec3 FoliageRotateNormal(in vec3 n, in vec3 rest, in vec3 bent)
{
	vec3 a = normalize(rest);
	vec3 b = normalize(bent);
	vec3 axis = cross(a, b);
	float s = length(axis);
	float c = dot(a, b);
	if (s < 1e-5)
		return n;
	axis /= s;
	return n * c + cross(axis, n) * s + axis * (dot(axis, n) * (1.0 - c));
}
