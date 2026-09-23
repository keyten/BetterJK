/*[Vertex]*/
void main()
{
	vec2 position = vec2(2.0 * float(gl_VertexID & 2) - 1.0, 4.0 * float(gl_VertexID & 1) - 1.0);
	gl_Position = vec4(position, 0.0, 1.0);
}

/*[Fragment]*/
// r_volumetricFogDebug views of the froxel fog (tr_volumetric.cpp), drawn over the tone mapped frame:
//
//  1  density: optical depth between the camera and the scene (blue 0 .. red 4 and more)
//  2  sun in-scattering without shadows          (the injection keeps only that light term)
//  3  sun in-scattering with the shadow maps
//  4  dynamic light in-scattering
//  5  baked (light grid) in-scattering
//  6  in-scattering of all the lights
//  7  transmittance
//  8  temporal history weight, averaged over the fogged froxels in front of the scene (red: no fog)
//  9  integrated volume: in-scattering over black, faded where transmittance is low
//  10 froxel slice index at the scene depth, froxel grid lines
//  11 density of the BSP fog volumes only       (the injection drops the height fog)
//  12 density of the height fog only            (the injection drops the BSP fog volumes)

uniform sampler2D u_ScreenDepthMap;
uniform sampler3D u_FroxelSource;	// injected volume: rgb / a = history weight in view 8

out vec4 out_Color;

vec3 Heat(in float x)
{
	x = clamp(x, 0.0, 1.0);
	return clamp(vec3(1.5 - abs(4.0 * x - 3.0), 1.5 - abs(4.0 * x - 2.0), 1.5 - abs(4.0 * x - 1.0)), 0.0, 1.0);
}

vec3 Display(in vec3 hdr)
{
	return hdr / (1.0 + hdr);
}

void main()
{
	vec2 tc = gl_FragCoord.xy / r_FBufScale;
	float depth = texture(u_ScreenDepthMap, tc).r;
	vec3 worldPos = FroxelSceneWorldPosition(tc, depth);
	vec4 fog = FroxelFog(worldPos);

	int view = int(u_FroxelDebugParams.x);
	vec3 color = vec3(0.0);

	if (view == 1 || view == 11 || view == 12)
	{
		color = Heat(-log(max(fog.a, 1e-4)) / 4.0);
	}
	else if (view >= 2 && view <= 6)
	{
		color = Display(fog.rgb);
	}
	else if (view == 7)
	{
		color = vec3(fog.a);
	}
	else if (view == 8)
	{
		vec4 clip = u_FroxelViewProjection * vec4(worldPos, 1.0);
		vec2 uv = clamp(clip.xy / max(clip.w, 1e-3) * 0.5 + 0.5, 0.0, 1.0);
		float d = dot(worldPos - u_FroxelViewOrigin.xyz, u_FroxelViewForward.xyz);
		int numSlices = int(u_FroxelGridSize.z);
		float sum = 0.0;
		float count = 0.0;
		for (int k = 0; k < numSlices; k++)
		{
			if (FroxelWToDepth(float(k) / float(numSlices)) > d)
				break;
			vec4 froxel = texture(u_FroxelSource, vec3(uv, (float(k) + 0.5) / float(numSlices)));
			if (froxel.a > 0.0)
			{
				sum += froxel.r / froxel.a;
				count += 1.0;
			}
		}
		color = (count > 0.0) ? vec3(sum / count) : vec3(0.5, 0.0, 0.0);
	}
	else if (view == 9)
	{
		color = Display(fog.rgb) + vec3(0.0, 0.0, 0.15) * (1.0 - fog.a);
	}
	else if (view == 10)
	{
		vec4 clip = u_FroxelViewProjection * vec4(worldPos, 1.0);
		vec2 uv = clamp(clip.xy / max(clip.w, 1e-3) * 0.5 + 0.5, 0.0, 1.0);
		float d = dot(worldPos - u_FroxelViewOrigin.xyz, u_FroxelViewForward.xyz);
		float slice = floor(FroxelDepthToW(min(d, u_FroxelSliceParams.y)) * u_FroxelGridSize.z);
		color = Heat(slice / u_FroxelGridSize.z);
		if (mod(slice, 2.0) > 0.5)
			color *= 0.7;
		vec2 cell = fract(uv * u_FroxelGridSize.xy);
		if (any(lessThan(cell, vec2(0.06))))
			color *= 0.5;
	}

	out_Color = vec4(color, 1.0);
}
