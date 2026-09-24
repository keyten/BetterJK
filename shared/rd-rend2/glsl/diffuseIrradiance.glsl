/*[Vertex]*/
out vec2 var_TexCoords;

void main()
{
	vec2 position = vec2(2.0 * float(gl_VertexID & 2) - 1.0,
		4.0 * float(gl_VertexID & 1) - 1.0);
	gl_Position = vec4(position, 0.0, 1.0);
	var_TexCoords = position;
}

/*[Geometry]*/
layout(triangles) in;
layout(triangle_strip, max_vertices = 18) out;

in vec2 var_TexCoords[];
out vec2 var_ScreenTex;
flat out int cubeFace;

void main()
{
	for (int face = 0; face < 6; ++face)
	{
		for (int i = 0; i < 3; ++i)
		{
			gl_Layer = face;
			gl_Position = vec4(var_TexCoords[i], -1.0, 1.0);
			var_ScreenTex = var_TexCoords[i];
			cubeFace = face;
			EmitVertex();
		}
		EndPrimitive();
	}
}

/*[Fragment]*/
uniform samplerCube u_CubeMap;
in vec2 var_ScreenTex;
flat in int cubeFace;
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

vec3 FaceDirection(vec2 uv, int face)
{
	if (face == 0) return normalize(vec3(1.0, -uv.y, -uv.x));
	if (face == 1) return normalize(vec3(-1.0, -uv.y, uv.x));
	if (face == 2) return normalize(vec3(uv.x, 1.0, uv.y));
	if (face == 3) return normalize(vec3(uv.x, -1.0, -uv.y));
	if (face == 4) return normalize(vec3(uv.x, -uv.y, 1.0));
	return normalize(vec3(-uv.x, -uv.y, -1.0));
}

void main()
{
	vec3 N = FaceDirection(var_ScreenTex, cubeFace);
	vec3 up = abs(N.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0);
	vec3 tangent = normalize(cross(up, N));
	vec3 bitangent = cross(N, tangent);
	vec3 irradianceOverPi = vec3(0.0);
	const uint samples = 128u;
	for (uint i = 0u; i < samples; ++i)
	{
		float u = (float(i) + 0.5) / float(samples);
		float phi = 2.0 * M_PI * RadicalInverse(i);
		float radius = sqrt(u);
		vec3 localDir = vec3(radius * cos(phi), radius * sin(phi), sqrt(1.0 - u));
		vec3 L = tangent * localDir.x + bitangent * localDir.y + N * localDir.z;
		// Cosine-weighted hemisphere PDF is (N dot L) / PI. Its Monte Carlo
		// estimator for irradiance / PI is the mean sampled radiance.
		irradianceOverPi += textureLod(u_CubeMap, L, 0.0).rgb;
	}
	out_Color = vec4(irradianceOverPi / float(samples), 1.0);
}
