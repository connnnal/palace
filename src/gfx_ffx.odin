package main

import "core:log"
import "core:math/linalg"

import "shaders"

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

// How many effects can we use per frame?
GFX_FFX_BLUR_CONCURRENT :: 12 * 3
GFX_FFX_BLUR_DESCRIPTORS :: 2

Gfx_Ffx_Blur_Context :: struct {
	pipeline:           ^d3d12.IPipelineState,
	root_sig:           ^d3d12.IRootSignature,
	descriptors:        Gfx_Descriptor_Handle(.CBV_SRV_UAV, BUFFER_COUNT * GFX_FFX_BLUR_CONCURRENT * GFX_FFX_BLUR_DESCRIPTORS),
	bb_idx, bb_idx_off: int,
}

gfx_ffx_blur_make :: proc(ctx: ^Gfx_Ffx_Blur_Context, allocator := context.allocator) {
	hr: win.HRESULT

	spec: shaders.Amd_Blur_Spec
	spec.wave = (.Wave_64 in gfx_ffx_state.has) ? ._64 : ._32
	spec.width = (.Half in gfx_ffx_state.has) ? .F16 : .F32
	spec.kernel_permutation = ._0
	spec.kernel_dimension = ._7

	blob := shaders.amd_blur(spec)

	hr = gfx_state.device->CreateComputePipelineState(&{CS = blob}, d3d12.IPipelineState_UUID, (^rawptr)(&ctx.pipeline))
	check(hr, "failed to create pipeline state")

	hr = gfx_state.device->CreateRootSignature(0, blob.pShaderBytecode, blob.BytecodeLength, d3d12.IRootSignature_UUID, (^rawptr)(&ctx.root_sig))
	check(hr, "failed to create root signature")

	gfx_descriptor_alloc(&ctx.descriptors)
}

gfx_ffx_blur_destroy :: proc(ctx: ^Gfx_Ffx_Blur_Context) {
	gfx_descriptor_free(ctx.descriptors)

	ctx.pipeline->Release()
	ctx.root_sig->Release()
}

gfx_ffx_blur_frame :: proc(ctx: ^Gfx_Ffx_Blur_Context, #any_int bb_idx: int) {
	ctx.bb_idx = bb_idx
	ctx.bb_idx_off = 0
}

gfx_ffx_blur_mount :: proc(ctx: ^Gfx_Ffx_Blur_Context, cmd_list: ^d3d12.IGraphicsCommandList, src, dst: ^d3d12.IResource, src_mip, dst_mip: u32) {
	src_desc: d3d12.RESOURCE_DESC
	src->GetDesc(&src_desc)

	constants: struct {
		image_size: [2]i32,
	}
	constants.image_size = {i32(src_desc.Width) >> src_mip, i32(src_desc.Height) >> src_mip}

	if linalg.min(constants.image_size) == 0 {
		// log.warnf("too small image size %v", constants.image_size)
		return
	}

	base_idx := (GFX_FFX_BLUR_DESCRIPTORS * GFX_FFX_BLUR_CONCURRENT) * ctx.bb_idx + GFX_FFX_BLUR_DESCRIPTORS * ctx.bb_idx_off
	log.assert(ctx.bb_idx_off < GFX_FFX_BLUR_CONCURRENT, "too many queued effects")
	defer ctx.bb_idx_off += 1

	gfx_state.device->CreateShaderResourceView(
		src,
		&{
			ViewDimension = .TEXTURE2D,
			Shader4ComponentMapping = d3d12.ENCODE_SHADER_4_COMPONENT_MAPPING(0, 1, 2, 3),
			Texture2D = {MostDetailedMip = src_mip, MipLevels = 1},
		},
		gfx_descriptor_cpu(ctx.descriptors, base_idx + 0),
	)
	gfx_state.device->CreateUnorderedAccessView(
		dst,
		nil,
		&{ViewDimension = .TEXTURE2D, Texture2D = {MipSlice = dst_mip}},
		gfx_descriptor_cpu(ctx.descriptors, base_idx + 1),
	)

	cmd_list->SetComputeRootSignature(ctx.root_sig)
	cmd_list->SetPipelineState(ctx.pipeline)
	cmd_list->SetComputeRoot32BitConstants(0, size_of(constants) / size_of(u32), &constants, 0)
	cmd_list->SetComputeRootDescriptorTable(1, gfx_descriptor_gpu(ctx.descriptors, base_idx))

	FFX_BLUR_TILE_SIZE_X :: 8
	FFX_BLUR_TILE_SIZE_Y :: 8
	FFX_BLUR_DISPATCH_Y :: 8

	cmd_list->Dispatch(u32(constants.image_size.x + FFX_BLUR_TILE_SIZE_X - 1) / FFX_BLUR_TILE_SIZE_X, FFX_BLUR_DISPATCH_Y, 1)
}

// How many effects can we use per frame?
GFX_FFX_SPD_CONCURRENT :: 4
GFX_FFX_SPD_DESCRIPTORS_IN_UAV :: 15
GFX_FFX_SPD_DESCRIPTORS_IN_SRV :: 1
GFX_FFX_SPD_DESCRIPTORS :: GFX_FFX_SPD_DESCRIPTORS_IN_SRV + GFX_FFX_SPD_DESCRIPTORS_IN_UAV

// Keep this in sync with the source shader headers!
GFX_FFX_SPD_GLOBAL_ATOMIC_SIZE :: 6 * size_of(u32)

Gfx_Ffx_Spd_Context :: struct {
	pipeline:           ^d3d12.IPipelineState,
	root_sig:           ^d3d12.IRootSignature,
	global_atomic:      ^d3d12.IResource,
	descriptors:        Gfx_Descriptor_Handle(.CBV_SRV_UAV, BUFFER_COUNT * GFX_FFX_SPD_CONCURRENT * GFX_FFX_SPD_DESCRIPTORS),
	bb_idx, bb_idx_off: int,
}

gfx_ffx_spd_make :: proc(ctx: ^Gfx_Ffx_Spd_Context) {
	hr: win.HRESULT

	spec: shaders.Amd_Single_Pass_Downsampler_Spec
	spec.wave = (.Wave_64 in gfx_ffx_state.has) ? ._64 : ._32
	spec.width = (.Half in gfx_ffx_state.has) ? .F16 : .F32
	spec.wave_interop_lds = (.Wave_Ops in gfx_ffx_state.has) ? .Yes : .No // TODO: Verify this feature check!
	spec.downsample_filter = .Mean

	blob := shaders.amd_single_pass_downsampler(spec)

	hr = gfx_state.device->CreateComputePipelineState(&{CS = blob}, d3d12.IPipelineState_UUID, (^rawptr)(&ctx.pipeline))
	check(hr, "failed to create pipeline state")

	hr = gfx_state.device->CreateRootSignature(0, blob.pShaderBytecode, blob.BytecodeLength, d3d12.IRootSignature_UUID, (^rawptr)(&ctx.root_sig))
	check(hr, "failed to create root signature")

	hr =
	gfx_state.device->CreateCommittedResource(
		&{Type = .DEFAULT},
		{},
		&{
			Dimension = .BUFFER,
			Width = GFX_FFX_SPD_GLOBAL_ATOMIC_SIZE,
			Height = 1,
			DepthOrArraySize = 1,
			MipLevels = 1,
			Format = .UNKNOWN,
			SampleDesc = {1, 0},
			Layout = .ROW_MAJOR,
			Flags = {.ALLOW_UNORDERED_ACCESS},
		},
		d3d12.RESOURCE_STATE_COMMON,
		nil,
		d3d12.IResource_UUID,
		(^rawptr)(&ctx.global_atomic),
	)
	check(hr, "failed to create ffx spd global atomic")

	gfx_descriptor_alloc(&ctx.descriptors)
}

gfx_ffx_spd_destroy :: proc(ctx: ^Gfx_Ffx_Spd_Context) {
	gfx_descriptor_free(ctx.descriptors)

	ctx.global_atomic->Release()
	ctx.pipeline->Release()
	ctx.root_sig->Release()
}

gfx_ffx_spd_frame :: proc(ctx: ^Gfx_Ffx_Spd_Context, #any_int bb_idx: int) {
	ctx.bb_idx = bb_idx
	ctx.bb_idx_off = 0
}

gfx_ffx_spd_mount :: proc(ctx: ^Gfx_Ffx_Spd_Context, cmd_list: ^d3d12.IGraphicsCommandList, src, dst: ^d3d12.IResource) {
	src_desc: d3d12.RESOURCE_DESC
	src->GetDesc(&src_desc)

	dst_desc: d3d12.RESOURCE_DESC
	dst->GetDesc(&dst_desc)

	dst_hi_mip := u32(dst_desc.MipLevels) - 1

	// Left, top, width, height
	rect_info: [4]u32 = {0, 0, u32(src_desc.Width), src_desc.Height}

	constants: struct {
		mips:              u32,
		num_work_groups:   u32,
		work_group_offset: [2]u32,
		inv_input_size:    [2]f32,
		padding:           [2]f32,
	}
	#assert(size_of(constants) == 8 * 4)
	constants.work_group_offset = rect_info.xy / 64

	endIndex := [2]u32{rect_info[0] + rect_info[2] - 1, rect_info[1] + rect_info[3] - 1} / 64
	dispatch_thread_group_count := endIndex + 1 - constants.work_group_offset

	constants.num_work_groups = dispatch_thread_group_count[0] * dispatch_thread_group_count[1]
	constants.mips = dst_hi_mip + 1

	constants.inv_input_size.x = 1 / f32(rect_info[2])
	constants.inv_input_size.y = 1 / f32(rect_info[3])

	base_idx := (GFX_FFX_SPD_DESCRIPTORS * GFX_FFX_SPD_CONCURRENT) * ctx.bb_idx + GFX_FFX_SPD_DESCRIPTORS * ctx.bb_idx_off
	log.assert(ctx.bb_idx_off < GFX_FFX_SPD_CONCURRENT, "too many queued effects")
	defer ctx.bb_idx_off += 1

	srv_base_idx := base_idx + 0
	uav_base_idx := base_idx + GFX_FFX_SPD_DESCRIPTORS_IN_SRV

	gfx_state.device->CreateShaderResourceView(src, nil, gfx_descriptor_cpu(ctx.descriptors, srv_base_idx + 0))

	gfx_state.device->CreateUnorderedAccessView(
		ctx.global_atomic,
		nil,
		&{ViewDimension = .BUFFER, Format = .UNKNOWN, Buffer = d3d12.BUFFER_UAV{NumElements = 1, StructureByteStride = GFX_FFX_SPD_GLOBAL_ATOMIC_SIZE}},
		gfx_descriptor_cpu(ctx.descriptors, uav_base_idx + 0),
	)

	// Maximum on 12 mipmaps. We must populate all slots, sadly.
	for mip in 0 ..= 12 {
		gfx_state.device->CreateUnorderedAccessView(
			dst,
			nil,
			&{ViewDimension = .TEXTURE2D, Texture2D = {MipSlice = min(u32(mip), dst_hi_mip)}},
			gfx_descriptor_cpu(ctx.descriptors, uav_base_idx + 2 + mip),
		)
	}
	gfx_state.device->CreateUnorderedAccessView(
		dst,
		nil,
		&{ViewDimension = .TEXTURE2D, Texture2D = {MipSlice = min(6, dst_hi_mip)}},
		gfx_descriptor_cpu(ctx.descriptors, uav_base_idx + 1),
	)

	cmd_list->SetComputeRootSignature(ctx.root_sig)
	cmd_list->SetPipelineState(ctx.pipeline)
	cmd_list->SetComputeRoot32BitConstants(0, size_of(constants) / size_of(u32), &constants, 0)
	cmd_list->SetComputeRootDescriptorTable(1, gfx_descriptor_gpu(ctx.descriptors, base_idx))

	cmd_list->Dispatch(dispatch_thread_group_count.x, dispatch_thread_group_count.y, 1)
}
