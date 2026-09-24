/*[Vertex]*/
out vec2 var_TexCoords;

void main()
{
	vec2 position = vec2(2.0 * float(gl_VertexID & 2) - 1.0,
	                     4.0 * float(gl_VertexID & 1) - 1.0);
	gl_Position = vec4(position, 0.0, 1.0);
	var_TexCoords = position * 0.5 + vec2(0.5);
}

/*[Fragment]*/
uniform sampler2D u_TextureMap;    // dedicated glow / emissive MRT
uniform sampler2D u_BloomSceneMap; // full HDR scene, optional source
// threshold, relative knee, scene contribution, linear-light framebuffer flag
uniform vec4 u_BloomParams;
in vec2 var_TexCoords;
out vec4 out_Color;

vec3 DecodeScene(vec3 value)
{
	if (u_BloomParams.w > 0.5)
		return max(value, vec3(0.0));
	value = max(value, vec3(0.0));
	vec3 lo = value / 12.92;
	vec3 hi = pow((value + vec3(0.055)) / 1.055, vec3(2.4));
	return mix(lo, hi, greaterThan(value, vec3(0.04045)));
}

void main()
{
	// The emissive MRT retains its texture mask and is never thresholded.
	vec3 emission = DecodeScene(texture(u_TextureMap, var_TexCoords).rgb);
	vec3 scene = vec3(0.0);
	if (u_BloomParams.z > 0.0)
	{
		scene = DecodeScene(texture(u_BloomSceneMap, var_TexCoords).rgb);
		float brightness = max(max(scene.r, scene.g), scene.b);
		float knee = max(u_BloomParams.x * u_BloomParams.y, 0.0001);
		float soft = clamp(brightness - u_BloomParams.x + knee, 0.0, 2.0 * knee);
		soft = soft * soft / (4.0 * knee);
		float contribution = max(brightness - u_BloomParams.x, soft) / max(brightness, 0.0001);
		scene *= contribution * u_BloomParams.z;
	}
	out_Color = vec4(emission + scene, 1.0);
}
