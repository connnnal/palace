#pragma once

struct DrawConstants {
	float2 viewport;
	float2 viewport_inv;
	uint accum_idx;
};
ConstantBuffer<DrawConstants> draw_constants : register(b0, space0);

SamplerState sampler_wrap_point : register(s0);
SamplerState sampler_wrap_linear : register(s1);
