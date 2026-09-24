/*[Vertex]*/
void main()
{
	vec2 position = vec2(2.0 * float(gl_VertexID & 2) - 1.0,
		4.0 * float(gl_VertexID & 1) - 1.0);
	gl_Position = vec4(position, 0.0, 1.0);
}

/*[Fragment]*/
uniform samplerCube u_CubeMap;
out vec4 out_Color;

float RadicalInverse(uint bits)
{
	bits = (bits << 16u) | (bits >> 16u);
	bits = ((bits & 0x55555555u) << 1u) | ((bits & 0xAAAAAAAAu) >> 1u);
	bits = ((bits & 0x33333333u) << 2u) | ((bits & 0xCCCCCCCCu) >> 2u);
	bits = ((bits & 0x0F0F0F0Fu) << 4u) | ((bits & 0xF0F0F0F0u) >> 4u);
	bits = ((bits & 0x00FF00FFu) << 8u) | ((bits & 0xFF00FF00u) >> 8u);
	return float(bits) * 2.3283064365386963e-10;
}

void main()
{
	// Uniform solid-angle sampling, independent of cubemap face distortion.
	const uint samples = 512u;
	vec3 averageRadiance = vec3(0.0);
	for (uint i = 0u; i < samples; ++i)
	{
		float z = 1.0 - 2.0 * (float(i) + 0.5) / float(samples);
		float phi = 2.0 * M_PI * RadicalInverse(i);
		float radius = sqrt(max(0.0, 1.0 - z * z));
		vec3 direction = vec3(radius * cos(phi), radius * sin(phi), z);
		averageRadiance += textureLod(u_CubeMap, direction, 0.0).rgb;
	}
	out_Color = vec4(averageRadiance / float(samples), 1.0);
}
