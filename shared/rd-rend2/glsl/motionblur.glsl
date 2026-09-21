/*[Vertex]*/
void main()
{
	vec2 position = vec2(2.0 * float(gl_VertexID & 2) - 1.0, 4.0 * float(gl_VertexID & 1) - 1.0);
	gl_Position = vec4(position, 0.0, 1.0);
}

/*[Fragment]*/
// Velocity based motion blur (camera and objects), tr_motionblur.cpp.
//
// Runs on the HDR scene before bloom, tone mapping and the UI. Every pixel
// gathers the scene along its own screen space motion during the exposure
// (the shutter interval is centered on the rendered frame), with the
// reconstruction filter weights of McGuire et al. 2012, "A Reconstruction
// Filter for Plausible Motion Blur": depth aware, so a blurry foreground
// covers the background, a blurry object reveals what is behind it, and a
// fast background does not smear into a still foreground.
//
// Velocity: the velocity buffer (velocity.glsl, current - previous position
// in texture coordinates for one frame) where the depth prepass wrote it;
// the camera motion reprojected from the depth buffer for the sky (and
// everywhere when there is no velocity buffer). One representation for
// camera and object motion.
//
// USE_LOW_QUALITY: the samples use the center velocity instead of their own.
// USE_DEBUG: r_motionBlurDebug views, displayed as they are (no tone map).

uniform sampler2D u_ScreenImageMap; // HDR scene
uniform sampler2D u_VelocityMap;    // rg = current - previous texture coordinates
uniform sampler2D u_ScreenDepthMap; // hardware depth

uniform mat4 u_MBInvViewProjection;  // inverse of the current view projection
uniform mat4 u_MBPrevViewProjection; // view projection of the previous frame
uniform vec4 u_MBParams;  // x = exposure / frame interval, y = max length (px), z = max samples, w = velocity buffer valid
uniform vec4 u_MBParams2; // x = view model scale, y = P[14], z = P[10], w = display encoded HDR buffer
uniform vec4 u_MBParams3; // x = debug view

out vec4 out_Color;

// Depth values <= DEPTH_HACK_MAX come from RF_DEPTHHACK surfaces (first
// person view model, glDepthRange(0, 0.3)), see gtao_depth.glsl
#define DEPTH_HACK_MAX 0.3001

// relative depth range over which two surfaces blend from "same surface" to
// "in front / behind"
#define SOFT_Z_RELATIVE 0.03
#define SOFT_Z_MIN 2.0

vec2 g_screenSize;

float LinearDepth(float d)
{
	// the view model is always in front of everything
	if (d <= DEPTH_HACK_MAX)
		return 1.0;
	return u_MBParams2.y / (2.0 * d - 1.0 + u_MBParams2.z);
}

// Texture coordinate motion of a static world point over the last frame (the
// camera motion). The sky is at infinity: only the camera rotation counts.
vec2 CameraVelocity(vec2 uv, float d)
{
	vec2 ndc = uv * 2.0 - 1.0;
	vec4 prevClip;
	if (d >= 1.0)
	{
		vec4 farPoint = u_MBInvViewProjection * vec4(ndc, 1.0, 1.0);
		vec4 nearPoint = u_MBInvViewProjection * vec4(ndc, -1.0, 1.0);
		vec3 dir = farPoint.xyz / farPoint.w - nearPoint.xyz / nearPoint.w;
		prevClip = u_MBPrevViewProjection * vec4(dir, 0.0);
	}
	else
	{
		vec4 worldPos = u_MBInvViewProjection * vec4(ndc, d * 2.0 - 1.0, 1.0);
		prevClip = u_MBPrevViewProjection * vec4(worldPos.xyz / worldPos.w, 1.0);
	}

	// behind the previous camera
	if (prevClip.w <= 1e-4)
		return vec2(0.0);

	return uv - (prevClip.xy / prevClip.w * 0.5 + 0.5);
}

// Frame velocity (texture coordinates) -> pixels covered during the exposure,
// view model attenuation and length clamp
vec2 ExposureVelocity(vec2 v, float d)
{
	v *= g_screenSize * u_MBParams.x;
	if (d <= DEPTH_HACK_MAX)
		v *= u_MBParams2.x;

	float len = length(v);
	if (len > u_MBParams.y)
		v *= u_MBParams.y / len;
	return v;
}

vec2 FrameVelocity(ivec2 pix, vec2 uv, float d)
{
	if (u_MBParams.w > 0.5 && d < 1.0)
		return texelFetch(u_VelocityMap, pix, 0).rg;
	if (d <= DEPTH_HACK_MAX)
		return vec2(0.0); // no velocity buffer: view model moves with the camera
	return CameraVelocity(uv, d);
}

vec2 PixelVelocity(ivec2 pix, float d)
{
	vec2 uv = (vec2(pix) + 0.5) / g_screenSize;
	return ExposureVelocity(FrameVelocity(pix, uv, d), d);
}

// Velocity that decides the sampling direction and length of a pixel. The
// pixel's own velocity for now; a tile / neighbour max velocity (McGuire's
// NeighborMax) can be returned here later so fast thin objects also blur
// onto the background around them.
vec2 DominantVelocity(ivec2 pix, float d)
{
	return PixelVelocity(pix, d);
}

vec3 DecodeColor(vec3 c)
{
	// the legacy HDR buffer holds display encoded values: integrate light in
	// linear space so bright highlights keep their energy
	return u_MBParams2.w > 0.5 ? pow(max(c, vec3(0.0)), vec3(2.2)) : c;
}

vec3 EncodeColor(vec3 c)
{
	return u_MBParams2.w > 0.5 ? pow(max(c, vec3(0.0)), vec3(1.0 / 2.2)) : c;
}

// 1 when depth a is at or in front of depth b, 0 when clearly behind
float SoftDepthCloser(float za, float zb)
{
	float extent = max(SOFT_Z_MIN, SOFT_Z_RELATIVE * min(za, zb));
	return clamp(1.0 - (za - zb) / extent, 0.0, 1.0);
}

float Cone(float dist, float radius)
{
	return clamp(1.0 - dist / max(radius, 1e-3), 0.0, 1.0);
}

float Cylinder(float dist, float radius)
{
	return 1.0 - smoothstep(0.95 * radius, 1.05 * radius, dist);
}

float InterleavedGradientNoise(vec2 pix)
{
	return fract(52.9829189 * fract(dot(pix, vec2(0.06711056, 0.00583715))));
}

int SampleCount(float len)
{
	// about one sample per 2 pixels of streak, up to the quality limit
	return clamp(int(ceil(len * 0.5)), 2, int(u_MBParams.z));
}

// Reconstruction filter. vX = exposure motion of this pixel in pixels; the
// samples cover [-0.5, 0.5] * vX, i.e. [-radius, radius] around the pixel.
vec3 Reconstruct(ivec2 pixX, vec3 colorX, float zX, vec2 vX, int numSamples)
{
	float radiusX = 0.5 * length(vX);
	ivec2 maxPix = ivec2(g_screenSize) - ivec2(1);

	float weight = 1.0 / max(radiusX, 1.0);
	vec3 sum = colorX * weight;

	float jitter = InterleavedGradientNoise(vec2(pixX));
	vec2 centerPos = vec2(pixX) + 0.5;

	for (int i = 0; i < numSamples; i++)
	{
		float t = mix(-0.5, 0.5, (float(i) + jitter) / float(numSamples));
		vec2 offset = vX * t;
		float dist = length(offset);

		vec2 posY = centerPos + offset;
		ivec2 pixY = clamp(ivec2(floor(posY)), ivec2(0), maxPix);
		if (pixY == pixX)
			continue;

		float dY = texelFetch(u_ScreenDepthMap, pixY, 0).r;
		float zY = LinearDepth(dY);
#if defined(USE_LOW_QUALITY)
		float radiusY = radiusX;
#else
		float radiusY = 0.5 * length(PixelVelocity(pixY, dY));
#endif

		float front = SoftDepthCloser(zY, zX); // Y in front of X
		float back = SoftDepthCloser(zX, zY);  // Y behind X

		float alphaY =
			front * Cone(dist, radiusY) +               // blurry Y covers X
			back * Cone(dist, radiusX) +                // blurry X reveals Y
			Cylinder(dist, radiusY) * Cylinder(dist, radiusX) * 2.0; // both blurry

		vec3 colorY = DecodeColor(textureLod(u_ScreenImageMap, posY / g_screenSize, 0.0).rgb);
		weight += alphaY;
		sum += colorY * alphaY;
	}

	return sum / weight;
}

#if defined(USE_DEBUG)
vec3 VelocityColor(vec2 v)
{
	// r/g = direction, brightness = length (relative to the max length)
	float len = length(v);
	if (len < 1e-3)
		return vec3(0.0);
	vec2 dir = v / len;
	float brightness = sqrt(clamp(len / u_MBParams.y, 0.0, 1.0));
	return vec3(0.5 + 0.5 * dir.x, 0.5 + 0.5 * dir.y, 0.25) * brightness;
}

vec3 HeatColor(float x)
{
	x = clamp(x, 0.0, 1.0);
	return clamp(vec3(x * 2.0 - 0.5, 1.0 - abs(x * 2.0 - 1.0), 1.5 - x * 2.0), 0.0, 1.0);
}
#endif

void main()
{
	g_screenSize = vec2(textureSize(u_ScreenImageMap, 0));

	ivec2 pix = ivec2(gl_FragCoord.xy);
	vec2 uv = (vec2(pix) + 0.5) / g_screenSize;
	vec4 center = texelFetch(u_ScreenImageMap, pix, 0);
	float dX = texelFetch(u_ScreenDepthMap, pix, 0).r;

	vec2 vX = DominantVelocity(pix, dX);
	float lenX = length(vX);

	// below half a pixel of motion nothing changes, full blur from 1.5 px
	float amount = smoothstep(0.5, 1.5, lenX);
	int numSamples = amount > 0.0 ? SampleCount(lenX) : 0;

	vec3 blurred = center.rgb;
	if (numSamples > 0)
	{
		vec3 colorX = DecodeColor(center.rgb);
		vec3 linearBlur = Reconstruct(pix, colorX, LinearDepth(dX), vX, numSamples);
		blurred = EncodeColor(mix(colorX, linearBlur, amount));
	}

#if defined(USE_DEBUG)
	int view = int(u_MBParams3.x);
	vec3 color;
	if (view == 1)
	{
		// velocity used for the blur
		color = VelocityColor(vX);
	}
	else if (view == 2)
	{
		// camera motion only, reconstructed from depth
		vec2 vCam = dX <= DEPTH_HACK_MAX ? vec2(0.0) : CameraVelocity(uv, dX);
		color = VelocityColor(ExposureVelocity(vCam, dX));
	}
	else if (view == 3)
	{
		// object motion: velocity buffer minus camera motion
		if (u_MBParams.w > 0.5 && dX < 1.0)
		{
			vec2 vObj = texelFetch(u_VelocityMap, pix, 0).rg;
			if (dX > DEPTH_HACK_MAX)
				vObj -= CameraVelocity(uv, dX);
			color = VelocityColor(ExposureVelocity(vObj, dX));
		}
		else
		{
			color = vec3(0.0, 0.0, 0.15); // no velocity data (sky / no velocity buffer)
		}
	}
	else if (view == 4)
	{
		// samples per pixel, black = skipped
		color = numSamples > 0 ? HeatColor(float(numSamples) / u_MBParams.z) : vec3(0.0);
	}
	else
	{
		// how much the blur changed the pixel
		vec3 diff = abs(DecodeColor(blurred) - DecodeColor(center.rgb));
		float change = dot(diff, vec3(0.2126, 0.7152, 0.0722));
		color = vec3(1.0 - exp(-4.0 * change));
	}
	out_Color = vec4(color, 1.0);
#else
	out_Color = vec4(blurred, center.a);
#endif
}
