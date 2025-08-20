#pragma once

// These parameters are all derived from our root signature.

struct DrawConstants
{
	// https://www.sebastiansylvan.com/post/matrix_naming_convention/.
	float2 viewport;
	float2 viewport_inv;
	uint accum_idx;
};
ConstantBuffer<DrawConstants> drawConstants : register(b999, space0);

SamplerState sampler_wrap_point : register(s100);
SamplerState sampler_wrap_linear : register(s101);

// struct DrawCommand {
// 	float3 position;
// 	float scale;
// 	vec4 orientation;
// };

// cbuffer DrawConstantBuffer : register(b0)
// {
// 	float3 position;
// 	float scale;
// 	float4 orientation;
// };
