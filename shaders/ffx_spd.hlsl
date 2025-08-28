// This file is part of the FidelityFX SDK.
//
// Copyright (C) 2024 Advanced Micro Devices, Inc.
// 
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files(the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and /or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions :
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

// SPD pass
// SRV  0 : SPD_InputDownsampleSrc          : r_input_downsample_src
// UAV  0 : SPD_InternalGlobalAtomic        : rw_internal_global_atomic
// UAV  1 : SPD_InputDownsampleSrcMidMip    : rw_input_downsample_src_mid_mip
// UAV  2 : SPD_InputDownsampleSrcMips      : rw_input_downsample_src_mips
// CB   0 : cbSPD

// The provided callback method assumes the texture is SRGB.
// So, we need to override that method.
// We still use register 0.
// #define FFX_SPD_BIND_SRV_INPUT_DOWNSAMPLE_SRC               0

#define FFX_SPD_BIND_UAV_INTERNAL_GLOBAL_ATOMIC             0
#define FFX_SPD_BIND_UAV_INPUT_DOWNSAMPLE_SRC_MID_MIPMAP    1
#define FFX_SPD_BIND_UAV_INPUT_DOWNSAMPLE_SRC_MIPS          2

#define FFX_SPD_BIND_CB_SPD                                 0

#include "spd/ffx_spd_callbacks_hlsl.h"

Texture2DArray<FfxFloat32x4> r_input_downsample_src : FFX_SPD_DECLARE_SRV(0);
#if FFX_HALF
	FfxFloat16x4 SampleSrcImageH(FfxFloat32x2 uv, FfxUInt32 slice)
	{
		FfxFloat32x2 textureCoord = FfxFloat32x2(uv) * InvInputSize() + InvInputSize();
		FfxFloat32x4 result = r_input_downsample_src.SampleLevel(s_LinearClamp, FfxFloat32x3(textureCoord, slice), 0);
		return result;
	}
#else
    FfxFloat32x4 SampleSrcImage(FfxInt32x2 uv, FfxUInt32 slice)
    {
        FfxFloat32x2 textureCoord = FfxFloat32x2(uv) * InvInputSize() + InvInputSize();
        FfxFloat32x4 result = r_input_downsample_src.SampleLevel(s_LinearClamp, FfxFloat32x3(textureCoord, slice), 0);
		return result;
    }
#endif

#include "spd/ffx_spd_downsample.h"

#ifndef FFX_SPD_THREAD_GROUP_WIDTH
#define FFX_SPD_THREAD_GROUP_WIDTH 256
#endif // #ifndef FFX_SPD_THREAD_GROUP_WIDTH
#ifndef FFX_SPD_THREAD_GROUP_HEIGHT
#define FFX_SPD_THREAD_GROUP_HEIGHT 1
#endif // FFX_SPD_THREAD_GROUP_HEIGHT
#ifndef FFX_SPD_THREAD_GROUP_DEPTH
#define FFX_SPD_THREAD_GROUP_DEPTH 1
#endif // #ifndef FFX_SPD_THREAD_GROUP_DEPTH
#ifndef FFX_SPD_NUM_THREADS
#define FFX_SPD_NUM_THREADS [numthreads(FFX_SPD_THREAD_GROUP_WIDTH, FFX_SPD_THREAD_GROUP_HEIGHT, FFX_SPD_THREAD_GROUP_DEPTH)]
#endif // #ifndef FFX_SPD_NUM_THREADS

#define CUSTOM_ROOT_SIG \
	"RootConstants(num32BitConstants=8, b0)," \
	"DescriptorTable(" \
		"SRV(t0, numDescriptors = 1, flags=DATA_VOLATILE)," \
		"UAV(u0, numDescriptors = 15, flags=DATA_VOLATILE)" \
	")," \
	"StaticSampler(s0, filter = FILTER_MIN_MAG_LINEAR_MIP_POINT, " \
		"addressU = TEXTURE_ADDRESS_CLAMP, " \
		"addressV = TEXTURE_ADDRESS_CLAMP, " \
		"addressW = TEXTURE_ADDRESS_CLAMP, " \
		"comparisonFunc = COMPARISON_NEVER, " \
		"borderColor = STATIC_BORDER_COLOR_TRANSPARENT_BLACK)"

FFX_PREFER_WAVE64
FFX_SPD_NUM_THREADS
[RootSignature(CUSTOM_ROOT_SIG)]
void CS(uint LocalThreadIndex : SV_GroupIndex, uint3 WorkGroupId : SV_GroupID)
{
    DOWNSAMPLE(LocalThreadIndex, WorkGroupId);
}
