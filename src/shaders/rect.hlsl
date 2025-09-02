#include "common.hlsl"

struct InputVs {
	float4             rect  : RECT;
	row_major float4x4 color : COLOR;
	float4             texc  : TEXC;
	uint4              pack  : PACK;
	uint               id    : SV_VertexID;
};
struct InputPs {
                    float4 pos        : SV_Position;
                    float4 color      : COLOR;
#ifdef SPEC_TEXTURE
                    float2 tex        : TEXCOORD0;
#endif
#if defined(SPEC_ROUNDED) || defined(SPEC_BORDER)
    nointerpolation float2 shape_size : CSIZE;
	                float2 shape_uv   : UVSHAPE;
#endif
	nointerpolation uint4  pack       : PACK;
};

uint pack_texi(uint4 pack) {
	return pack.x;
}
float pack_depth(uint4 pack) {
	return asfloat(0x800000 + (pack.y & 0xFFFF));
}
uint pack_border(uint4 pack) {
	return (pack.y >> 16) & 0xFF;
}
float4 pack_rounding(uint4 pack) {
	float radius = asfloat(pack.z);
	return float4(
		( pack.y & (0x1 << 24) ) ? radius : 0.f,
		( pack.y & (0x2 << 24) ) ? radius : 0.f,
		( pack.y & (0x4 << 24) ) ? radius : 0.f,
		( pack.y & (0x8 << 24) ) ? radius : 0.f
	);
}
float pack_hardness(uint4 pack) {
	return asfloat(pack.w);
}
bool pack_oklab(uint4 pack) {
	return (pack.y & (0x1 << 28)) > 0;
}
bool pack_glass(uint4 pack) {
	return (pack.y & (0x1 << 29)) > 0;
}

//
// https://github.com/patriciogonzalezvivo/lygia/blob/main/color/space/oklab2rgb.hlsl.
// https://github.com/patriciogonzalezvivo/lygia/blob/main/color/space/rgb2oklab.hlsl.
//
/*
contributors: Bjorn Ottosson (@bjornornorn)
description: Oklab to linear RGB https://bottosson.github.io/posts/oklab/
use: <float3\float4> oklab2rgb(<float3|float4> oklab)
license: 
    - MIT License (MIT) Copyright (c) 2020 Björn Ottosson
*/
float3 oklab2rgb(float3 oklab) {
	static const float3x3 OKLAB2RGB_A = float3x3(
		1.0,           1.0,           1.0,
		0.3963377774, -0.1055613458, -0.0894841775,
		0.2158037573, -0.0638541728, -1.2914855480);

	static const float3x3 OKLAB2RGB_B = float3x3(
		4.0767416621, -1.2684380046, -0.0041960863,
		-3.3077115913, 2.6097574011, -0.7034186147,
		0.2309699292, -0.3413193965, 1.7076147010);

	float3 lms = mul(OKLAB2RGB_A, oklab);
	return mul(OKLAB2RGB_B, (lms * lms * lms));
}
/*
contributors: Bjorn Ottosson (@bjornornorn)
description: |
    Linear rgb to OKLab https://bottosson.github.io/posts/oklab/
use: <float3\float4> rgb2oklab(<float3|float4> rgb)
license: 
    - MIT License (MIT) Copyright (c) 2020 Björn Ottosson
*/
float3 rgb2oklab(float3 rgb) {
	static const float3x3 RGB2OKLAB_A = float3x3(
		0.2104542553, 1.9779984951, 0.0259040371,
		0.7936177850, -2.4285922050, 0.7827717662,
		-0.0040720468, 0.4505937099, -0.8086757660);

	static const float3x3 RGB2OKLAB_B = float3x3(
		0.4122214708, 0.2119034982, 0.0883024619,
		0.5363325363, 0.6806995451, 0.2817188376,
		0.0514459929, 0.1073969566, 0.6299787005);

	float3 lms = mul(RGB2OKLAB_B, rgb);
	return mul(RGB2OKLAB_A, sign(lms) * pow(abs(lms), float3(0.3333333333333, 0.3333333333333, 0.3333333333333)));
}

// We're using an ubershader model.
// In the "uber" state, we consider options as enabling functionality, but not necessarily using it.
// In a "specialisation" state, we consider options used exactly as described.
// This allows us to eliminate branches as we compile more PSOs.
#ifdef SPEC_UBER
	#define UBER_IF(cond) if ( cond )
#else
	#define UBER_IF(cond) if ( true )
#endif

InputPs vs_main(InputVs input)
{
    InputPs output;

	float2 uv = float2(
		(input.id & 1) ? 1.0f : 0.0f,
		(input.id > 1) ? 1.0f : 0.0f
	);

	float2 shape_size = input.rect.yw;

	float4 pos = float4(
		input.rect.x + input.rect.y * uv.x,
		input.rect.z + input.rect.w * uv.y,
		0,
		1
	);
	pos.x *= draw_constants.viewport_inv.x;
	pos.y *= draw_constants.viewport_inv.y;
	pos.y = 1 - pos.y;
	pos.x = (pos.x - 0.5f) * 2.0f;
	pos.y = (pos.y - 0.5f) * 2.0f;
	pos.z = pack_depth(input.pack);
	output.pos = pos;
	
	// TODO: Faster than dynamic indexing?
	// TODO: Multiplying all columns before addition may be faster beacuse of latency hiding.
	float4 color = 0;
	color += (input.id == 0 ? input.color[0] : 0.0f);
	color += (input.id == 1 ? input.color[1] : 0.0f);
	color += (input.id == 2 ? input.color[2] : 0.0f);
	color += (input.id == 3 ? input.color[3] : 0.0f);
	color.xyz *= color.a;
#ifdef SPEC_OKLAB
	UBER_IF(pack_oklab(input.pack)) {
		// We inherit the alpha pre-multiply from above into this conversion.
		// I'm uncertain if we'll lose "precision" in Oklab space?
		// Regardless, this avoids a multiply in the pixel shader.
		color.xyz = rgb2oklab(color.xyz);
	}
#endif
	output.color = color;

#ifdef SPEC_TEXTURE
	output.tex = float2(
		input.texc.x + input.texc.y * uv.x,
		input.texc.z + input.texc.w * uv.y
	);
#endif

#ifdef SPEC_ROUNDED
	// Hardness is a fraction, need to reason with pixels here.
	float inset = 1 - 1 / pack_hardness(input.pack);
	float2 fac = inset / (2 * shape_size);

	output.shape_size = shape_size + inset;
	output.shape_uv = uv + (fac - 2 * uv * fac);
#endif

	output.pack = input.pack;

    return output;
}

//
// https://iquilezles.org/articles/roundedboxes/.
// https://www.shadertoy.com/view/4cG3R1.
//

float sdCornerCircle( float2 p )
{
    return length(p-float2(0.0,-1.0)) - sqrt(2.0);
}

float sdCornerParabola( float2 p )
{
    // https://www.shadertoy.com/view/ws3GD7
    float y = (0.5 + p.y)*(2.0/3.0);
    float h = p.x*p.x + y*y*y;
    float w = pow( p.x + sqrt(abs(h)), 1.0/3.0 ); // note I allow a tiny error in the very interior of the shape so that I don't have to branch into the 3 root solution
    float x = w - y/w;
    float2  q = float2(x,0.5*(1.0-x*x));
    return length(p-q)*sign(p.y-q.y);
}

float sdCornerCosine( float2 uv )
{
    // https://www.shadertoy.com/view/3t23WG
	const float kT = 6.28318531;
    uv *= (kT/4.0);

    float ta = 0.0, tb = kT/4.0;
    for( int i=0; i<8; i++ )
    {
        float t = 0.5*(ta+tb);
        float y = t-uv.x+(uv.y-cos(t))*sin(t);
        if( y<0.0 ) ta = t; else tb = t;
    }
    float2  qa = float2(ta,cos(ta)), qb = float2(tb,cos(tb));
    float2  pa = uv-qa;
	float2 di = qb-qa;
    float h = clamp( dot(pa,di)/dot(di,di), 0.0, 1.0 );
    return length(pa-di*h) * sign(pa.y*di.x-pa.x*di.y) * (4.0/kT);
}

float sdCornerCubic( float2 uv )
{
    float ta = 0.0, tb = 1.0;
    for( int i=0; i<12; i++ )
    {
        float t = 0.5*(ta+tb);
        float c = (t*t*(t-3.0)+2.0)/3.0;
        float dc = t*(t-2.0);
        float y = (uv.x-t) + (uv.y-c)*dc;
        if( y>0.0 ) ta = t; else tb = t;
    }
    float2  qa = float2(ta,(ta*ta*(ta-3.0)+2.0)/3.0);
    float2  qb = float2(tb,(tb*tb*(tb-3.0)+2.0)/3.0);
    float2  pa = uv-qa, di = qb-qa;
    float h = clamp( dot(pa,di)/dot(di,di),0.0,1.0 );
    return length(pa-di*h) * sign(pa.y*di.x-pa.x*di.y);
}

float sdRoundBox( float2 p, float2 b, float4 r, int type )
{
    // select corner radius
    r.xy = (p.x>0.0)?r.xy : r.zw;
    r.x  = (p.y>0.0)?r.x  : r.y;
    // box coordinates
    float2 q = abs(p)-b+r.x;
    // distance to sides
    if( min(q.x,q.y)<0.0 ) return max(q.x,q.y)-r.x;
    // rotate 45 degrees, offset by r and scale by r*sqrt(0.5) to canonical corner coordinates
    float2 uv = float2( abs(q.x-q.y), q.x+q.y-r.x )/r.x;
    // compute distance to corner shape
    float d;
         if( type==0 ) d = sdCornerCircle( uv );
    else if( type==1 ) d = sdCornerParabola( uv );
    else if( type==2 ) d = sdCornerCosine( uv );
    else if( type==3 ) d = sdCornerCubic( uv );
    // undo scale
    return d * r.x*sqrt(0.5);
}

//
// https://julhe.github.io/posts/always_sharp_sdf_textures/.
//

//inverse of lerp(), you can also use smoothstep() if you want to.
#define inverseLerp(a,b,x) ((x-a)/(b-a))

// Good enough for most cases. Can show up minor artifacts on step triangles
half FilterSdfTextureApproximative(half sdf, float2 uvCoordinate, half2 textureSize) {
    half2 pixelAreaRect = fwidth(uvCoordinate) * textureSize; // calculate the area under the pixel
    half texelCoverage = saturate(min(pixelAreaRect.x, pixelAreaRect.y));
    return saturate(inverseLerp(-texelCoverage, texelCoverage, sdf));
}

// exact version
half FilterSdfTextureExact(half sdf, float2 uvCoordinate, half2 textureSize) {
    // calculate the derrivate of the UV coordinate and build a parallelogramm from it
    half2x2 pixelFootprint = half2x2(ddx(uvCoordinate), ddy(uvCoordinate));
    half pixelFootprintDiameterSqr = abs(determinant(pixelFootprint)); 
    pixelFootprintDiameterSqr *= textureSize.x * textureSize.y ;
    float pixelFootprintDiameter = sqrt(pixelFootprintDiameterSqr);
    // clamp the filter width to [0, 1] so we won't overfilter, which fades the texture into grey
    pixelFootprintDiameter = saturate(pixelFootprintDiameter) ; 
    return (inverseLerp(-pixelFootprintDiameter, pixelFootprintDiameter, sdf));
}

//
// https://www.shadertoy.com/view/tlcBRl.
//

float noise1(float seed1,float seed2){
	return(
	frac(seed1+12.34567*
	frac(100.*(abs(seed1*0.91)+seed2+94.68)*
	frac((abs(seed2*0.41)+45.46)*
	frac((abs(seed2)+757.21)*
	frac(seed1*0.0171))))))
	* 1.0038 - 0.00185;
}

float4 ps_main(InputPs input) : SV_Target
{
	float4 color = input.color;

	uint texi = pack_texi(input.pack);
	float4 corner = pack_rounding(input.pack);
	float hardness = pack_hardness(input.pack);
	float border = pack_border(input.pack);
	bool oklab = pack_oklab(input.pack);
	bool glass = pack_glass(input.pack);

#ifdef SPEC_OKLAB
	UBER_IF(oklab) {
		color.xyz = oklab2rgb(color.xyz);
	}
#endif

#ifdef SPEC_TEXTURE
	if (texi != 0xFFFFFFFF) {
	    Texture2D texture = ResourceDescriptorHeap[NonUniformResourceIndex(texi)];
	    color *= texture.Sample(sampler_wrap_point, input.tex);
	}
#endif

#ifdef SPEC_ROUNDED
	float dist = sdRoundBox((input.shape_uv*2-1)*input.shape_size, input.shape_size, corner, 1);

	#ifdef SPEC_BORDER
		UBER_IF(border > 0) {
			// TODO: This math for nesting corner radii feels optically incorrect.
			float dist_inner = sdRoundBox((input.shape_uv * 2 - 1) * input.shape_size, input.shape_size - 2 * border, max(0, corner - border * 2), 1);
			dist = max(dist, -dist_inner);
		}
	#endif

	float alpha = FilterSdfTextureApproximative(-dist * hardness, input.shape_uv, input.shape_size);
	if (hardness < 0.5) {
		alpha = smoothstep(0,1,alpha);
	}
	color *= alpha;
#else
	#ifdef SPEC_BORDER
		// TODO: Faster to use discard here?
		float2 shape_px = input.shape_uv * input.shape_size;
		float alpha = (
			( shape_px.x > border )
			&& ( shape_px.x - input.shape_size.x < -border )
			&& ( shape_px.y > border )
			&& ( shape_px.y - input.shape_size.y < -border )
		) ? 0.f : 1.f;
		color *= alpha;
	#endif
#endif

#ifdef SPEC_GLASS
	UBER_IF(glass) {
		float2 input_pos_frac = input.pos.xy * draw_constants.viewport_inv;

		Texture2D texture_prev = ResourceDescriptorHeap[draw_constants.accum_idx];
		float3 accum = 0;
		uint mip_start = 3;
		uint mip_end = 7;
		for (int i = mip_start; i < mip_end; i++) {
			accum += texture_prev.SampleLevel(sampler_wrap_linear, input_pos_frac, i).xyz;
		}
		color.xyz *= accum / float(mip_end - mip_start);
		color.xyz *= lerp( .95f, 1.f, noise1(input_pos_frac.x, input_pos_frac.y) );
	}
#endif

    return color;
}
