package main

import "core:log"

import "build:shaders"

import win "core:sys/windows"
import "vendor:directx/d3d12"

Gfx_Ffx_Has :: enum i32 {
	Sm_6_6,
	Wave_64,
	Half,
	Wave_Ops,
}

gfx_ffx_state: struct {
	has:    bit_set[Gfx_Ffx_Has],
	combos: [shaders.AMD_BLUR_KEY_CAP]^d3d12.IPipelineState,
}

@(private)
gfx_ffx_init :: proc() {
	hr: win.HRESULT

	has_sm_6_6 := false
	{
		desc: d3d12.FEATURE_DATA_SHADER_MODEL
		desc.HighestShaderModel = ._6_6
		hr = gfx_state.device->CheckFeatureSupport(.SHADER_MODEL, &desc, size_of(desc))
		has_sm_6_6 = win.SUCCEEDED(hr) && desc.HighestShaderModel == ._6_6
	}

	// Note that waves are tyically 32, i.e. on Nvidia.
	has_wave_64 := false
	has_wave_ops := false
	if has_sm_6_6 {
		desc: d3d12.FEATURE_DATA_OPTIONS1
		hr = gfx_state.device->CheckFeatureSupport(.OPTIONS1, &desc, size_of(desc))
		has_wave_64 = win.SUCCEEDED(hr) && (desc.WaveLaneCountMin <= 64 && desc.WaveLaneCountMax >= 64)
		has_wave_ops = win.SUCCEEDED(hr) && desc.WaveOps
	}

	has_half := false
	{
		desc: d3d12.FEATURE_DATA_OPTIONS
		hr = gfx_state.device->CheckFeatureSupport(.OPTIONS, &desc, size_of(desc))
		has_half = win.SUCCEEDED(hr) && (._16_BIT in desc.MinPrecisionSupport)
	}
	{
		desc: d3d12.FEATURE_DATA_OPTIONS4
		hr = gfx_state.device->CheckFeatureSupport(.OPTIONS4, &desc, size_of(desc))
		has_half &&= win.SUCCEEDED(hr) && desc.Native16BitShaderOpsSupported
	}

	gfx_ffx_state.has |= has_sm_6_6 ? {.Sm_6_6} : {}
	gfx_ffx_state.has |= has_wave_64 ? {.Wave_64} : {}
	gfx_ffx_state.has |= has_half ? {.Half} : {}
	gfx_ffx_state.has |= has_wave_ops ? {.Wave_Ops} : {}

	log.infof("ffx support; sm_6_6: %v, wave_64: %v, fp16: %v, waveops: %v", has_sm_6_6, has_wave_64, has_half, has_wave_ops)
}

@(private)
gfx_ffx_fini :: proc "contextless" () {

}

Gfx_Ffx_Blur_Constants :: struct {
	image_size: [2]i32,
}
Gfx_Ffx_Blur_Context :: struct {
	pipeline: ^d3d12.IPipelineState,
	buffer:   ^d3d12.IResource,
	root_sig: ^d3d12.IRootSignature,
}
Gfx_Ffx_Blur_Cmd :: struct {
	using ctx: ^Gfx_Ffx_Blur_Context,
	table:     Gfx_Descriptor_Handle,
	constants: Gfx_Ffx_Blur_Constants,
}

gfx_ffx_blur_make :: proc(ctx: ^Gfx_Ffx_Blur_Context) {
	hr: win.HRESULT

	spec: shaders.Amd_Blur_Spec
	spec.wave = (.Wave_64 in gfx_ffx_state.has) ? ._64 : ._32
	spec.width = (.Half in gfx_ffx_state.has) ? .F16 : .F32
	spec.kernel_permutation = ._2
	spec.kernel_dimension = ._7

	blob := shaders.amd_blur(spec)

	hr = gfx_state.device->CreateComputePipelineState(&{CS = blob}, d3d12.IPipelineState_UUID, (^rawptr)(&ctx.pipeline))
	check(hr, "failed to create pipeline state")

	hr = gfx_state.device->CreateRootSignature(0, blob.pShaderBytecode, blob.BytecodeLength, d3d12.IRootSignature_UUID, (^rawptr)(&ctx.root_sig))
	check(hr, "failed to create root signature")
}

gfx_ffx_blur_destroy :: proc(ctx: ^Gfx_Ffx_Blur_Context) {
	ctx.pipeline->Release()
	ctx.root_sig->Release()
}

gfx_ffx_blur_cmd :: proc(ctx: ^Gfx_Ffx_Blur_Context, src, dst: ^d3d12.IResource, src_mip, dst_mip: u32) -> (cmd: Gfx_Ffx_Blur_Cmd) {
	src_desc: d3d12.RESOURCE_DESC
	src->GetDesc(&src_desc)

	cmd.ctx = ctx
	cmd.constants = {
		image_size = {i32(src_desc.Width), i32(src_desc.Height)},
	}

	cmd.table = gfx_descriptor_alloc(.CBV_SRV_UAV_MULTI)

	gfx_state.device->CreateShaderResourceView(
		src,
		&{
			ViewDimension = .TEXTURE2D,
			Shader4ComponentMapping = d3d12.ENCODE_SHADER_4_COMPONENT_MAPPING(0, 1, 2, 3),
			Texture2D = {MostDetailedMip = src_mip, MipLevels = 1},
		},
		gfx_descriptor_cpu(cmd.table, 0),
	)
	gfx_state.device->CreateUnorderedAccessView(dst, nil, &{ViewDimension = .TEXTURE2D, Texture2D = {MipSlice = dst_mip}}, gfx_descriptor_cpu(cmd.table, 1))

	return
}

gfx_ffx_blur_mount :: proc(cmd: ^Gfx_Ffx_Blur_Cmd, cmd_list: ^d3d12.IGraphicsCommandList) {
	cmd_list->SetComputeRootSignature(cmd.root_sig)
	cmd_list->SetPipelineState(cmd.pipeline)

	cmd_list->SetComputeRoot32BitConstants(0, size_of(cmd.constants) / size_of(u32), &cmd.constants, 0)

	cmd_list->SetComputeRootDescriptorTable(1, gfx_descriptor_gpu(cmd.table))

	FFX_BLUR_TILE_SIZE_X :: 8
	FFX_BLUR_TILE_SIZE_Y :: 8
	FFX_BLUR_DISPATCH_Y :: 8

	cmd_list->Dispatch(u32(cmd.constants.image_size.x + FFX_BLUR_TILE_SIZE_X - 1) / FFX_BLUR_TILE_SIZE_X, FFX_BLUR_DISPATCH_Y, 1)
}
