package main

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math/bits"
import "core:math/linalg"
import "core:sync"
import "core:sync/chan"
import "core:thread"

import win "core:sys/windows"
import "vendor:directx/d3d12"
import "vendor:directx/dxgi"

import "lib:superluminal"

import "shaders"

@(export, private, link_name = "NvOptimusEnablement")
NvOptimusEnablement: u32 = 0x00000001
@(export, private, link_name = "AmdPowerXpressRequestHighPerformance")
AmdPowerXpressRequestHighPerformance: i32 = 1

@(export, private, link_name = "D3D12SDKVersion")
D3D12SDKVersion := 616
@(export, private, link_name = "D3D12SDKPath")
D3D12SDKPath := ".\\lib\\microsoft.direct3d.d3d12.1.616.1\\build\\native\\bin\\x64\\"

GFX_COLOR := superluminal.MAKE_COLOR(255, 0, 255)

GFX_DEBUG :: #config(USE_GFX_DEBUG, false)

Gfx_Pass_Offscreen :: enum {
	Render,
	Downsample,
	Working,
}

Gfx_Pipeline_Phase :: enum {
	Unwanted,
	Signalled,
	Ready,
}

gfx_state: struct {
	adapter:         ^dxgi.IAdapter,
	device:          ^d3d12.IDevice4,
	queue:           ^d3d12.ICommandQueue,
	dxgi_factory:    ^dxgi.IFactory6,
	root_sig:        ^d3d12.IRootSignature,
	// Device sync.
	halt_fence:      ^d3d12.IFence,
	halt_value:      u64,
	// Pipeline manager.
	pipelines:       [GFX_RECT_CAP_PERMS]struct #min_field_align(64) {
		state: ^d3d12.IPipelineState,
		phase: sync.Futex,
	},
	pipeline_chan:   chan.Chan(Gfx_Rect_Caps),
	// TODO: Upstream that a zero-initialised thread is considered done.
	pipeline_thread: ^thread.Thread,
}

@(init)
gfx_init :: proc "contextless" () {
	context = default_context()

	superluminal.InstrumentationScope("Gfx Init", color = GFX_COLOR)

	hr: win.HRESULT

	dxgi_factory_flags: dxgi.CREATE_FACTORY
	when GFX_DEBUG {
		debug: ^d3d12.IDebug1
		hr = d3d12.GetDebugInterface(d3d12.IDebug1_UUID, cast(^rawptr)&debug)
		check(hr, "failed to get debug interface")
		debug->EnableDebugLayer()
		debug->SetEnableGPUBasedValidation(false) // TODO: Place behind command line args.
		debug->Release()

		info_queue: ^dxgi.IInfoQueue
		hr = dxgi.DXGIGetDebugInterface1(0, dxgi.IInfoQueue_UUID, cast(^rawptr)&info_queue)
		check(hr, "failed to get dxgi debug info queue")
		info_queue->SetBreakOnSeverity(dxgi.DEBUG_ALL, .ERROR, true)
		info_queue->SetBreakOnSeverity(dxgi.DEBUG_ALL, .CORRUPTION, true)
		info_queue->Release()

		dxgi_factory_flags += {.DEBUG}
	}

	hr = dxgi.CreateDXGIFactory2(dxgi_factory_flags, dxgi.IFactory6_UUID, cast(^rawptr)&gfx_state.dxgi_factory)
	check(hr, "failed to create dxgi factory")

	find_adapter: {
		MIN_FEATURELEVEL :: d3d12.FEATURE_LEVEL._12_0
		// Highest for bindless. Ideally support a fallback!
		MIN_SHADERMODEL :: d3d12.SHADER_MODEL._6_6

		_adapter: ^dxgi.IAdapter1
		for idx: u32; gfx_state.dxgi_factory->EnumAdapterByGpuPreference(idx, .HIGH_PERFORMANCE, dxgi.IAdapter1_UUID, (^rawptr)(&_adapter)) == win.S_OK; idx += 1 {
			desc: dxgi.ADAPTER_DESC1
			_adapter->GetDesc1(&desc)
			defer _adapter->Release()

			// TODO: Allow WARP in the worst case.
			if .SOFTWARE in desc.Flags {continue}
			if .REMOTE in desc.Flags {continue}

			_device: ^d3d12.IDevice4
			hr = d3d12.CreateDevice(_adapter, MIN_FEATURELEVEL, d3d12.IDevice4_UUID, (^rawptr)(&_device))
			win.SUCCEEDED(hr) or_continue
			defer _device->Release()

			// https://learn.microsoft.com/en-us/windows/win32/api/d3d12/ne-d3d12-d3d12_resource_heap_tier.
			feat_op: d3d12.FEATURE_DATA_OPTIONS
			hr = _device->CheckFeatureSupport(.OPTIONS, &feat_op, size_of(feat_op))
			win.SUCCEEDED(hr) or_continue

			// https://learn.microsoft.com/en-us/windows/win32/api/d3d12/ns-d3d12-d3d12_feature_data_shader_model.
			feat_sm: d3d12.FEATURE_DATA_SHADER_MODEL = {MIN_SHADERMODEL}
			hr = _device->CheckFeatureSupport(.SHADER_MODEL, &feat_sm, size_of(feat_sm))
			(win.SUCCEEDED(hr) && feat_sm.HighestShaderModel >= MIN_SHADERMODEL) or_continue

			feat_op16: d3d12.FEATURE_DATA_OPTIONS16
			hr = _device->CheckFeatureSupport(.OPTIONS16, &feat_op16, size_of(feat_op16))
			has_gpu_upload_heap := win.SUCCEEDED(hr) && feat_op16.GPUUploadHeapSupported

			// Add refs to make these temp objects permanent.
			_device->AddRef()
			gfx_state.device = _device
			_adapter->AddRef()
			gfx_state.adapter = _adapter

			log.debugf(
				"using %s: %M mem, sm: %v, heap: %v, gpuheap: %v",
				desc.Description,
				desc.DedicatedVideoMemory,
				feat_sm.HighestShaderModel,
				feat_op.ResourceHeapTier,
				has_gpu_upload_heap,
			)

			break find_adapter
		}

		log.panic("failed to create capable device")
	}

	hr = gfx_state.device->CreateFence(gfx_state.halt_value, nil, d3d12.IFence_UUID, (^rawptr)(&gfx_state.halt_fence))
	check(hr, "failed to create halt fence")

	// TODO: Only a graphics command queue for now (no copy!).
	hr = gfx_state.device->CreateCommandQueue(&{Type = .DIRECT}, d3d12.ICommandQueue_UUID, (^rawptr)(&gfx_state.queue))
	check(hr, "failed to create command queue")

	// TODO: Check LSP correctly handles "expand_values" in method arguments.
	sig_bin := shaders.root_signature({})
	hr = gfx_state.device->CreateRootSignature(0, expand_values(sig_bin), d3d12.IRootSignature_UUID, (^rawptr)(&gfx_state.root_sig))
	check(hr, "failed to create root signature")

	gfx_state.pipeline_chan = chan.create_buffered(type_of(gfx_state.pipeline_chan), 1024, context.allocator) or_else log.panic("failed to create pipeline queue")
	gfx_state.pipeline_thread = thread.create_and_start(gfx_pipeline_runner, context)

	gfx_pipeline_query(GFX_RECT_CAPS_OPAQUE)
	gfx_pipeline_query(GFX_RECT_CAPS_UBER)

	gfx_descriptor_init()
	gfx_ffx_init()
}

@(fini)
gfx_fini :: proc "contextless" () {
	superluminal.InstrumentationScope("Gfx Fini", color = GFX_COLOR)

	context = default_context()

	chan.close(gfx_state.pipeline_chan)
	thread.destroy(gfx_state.pipeline_thread)

	gfx_descriptor_fini()

	gfx_state.adapter->Release()
	gfx_state.device->Release()
	gfx_state.queue->Release()
	gfx_state.dxgi_factory->Release()
	gfx_state.root_sig->Release()
	gfx_state.halt_fence->Release()

	gfx_ffx_fini()
}

@(private)
gfx_pipeline_query :: proc(caps: Gfx_Rect_Caps) -> (^d3d12.IPipelineState, bool) {
	pack := &gfx_state.pipelines[transmute(u8)caps]

	value := sync.atomic_load_explicit(&pack.phase, .Relaxed)
	switch Gfx_Pipeline_Phase(value) {
	case .Unwanted:
		_, swapped := sync.atomic_compare_exchange_strong(&pack.phase, sync.Futex(Gfx_Pipeline_Phase.Unwanted), sync.Futex(Gfx_Pipeline_Phase.Signalled))
		if swapped {
			chan.send(gfx_state.pipeline_chan, caps)
		}
		return nil, false
	case .Signalled:
		return nil, false
	case .Ready:
		return pack.state, true
	}
	unreachable()
}

@(private)
gfx_pipeline_expect :: proc(caps: Gfx_Rect_Caps) -> ^d3d12.IPipelineState {
	pack := &gfx_state.pipelines[transmute(u8)caps]
	log.assertf(pack.state != nil, "expected pipeline (caps: #%v)", caps)
	return pack.state
}

@(private)
gfx_pipeline_wait :: proc(caps: Gfx_Rect_Caps) {
	pack := &gfx_state.pipelines[transmute(u8)caps]

	for {
		value := sync.atomic_load_explicit(&pack.phase, .Relaxed)

		switch Gfx_Pipeline_Phase(value) {
		case .Unwanted:
			log.panicf("can't wait on unsignalled pipeline (caps: %#v)", caps)
		case .Signalled:
			continue
		case .Ready:
			return
		}

		sync.futex_wait(&pack.phase, u32(value))
	}
}

@(private)
gfx_pipeline_runner :: proc() {
	defer runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
	for caps in chan.recv(gfx_state.pipeline_chan) {
		pack := &gfx_state.pipelines[transmute(u8)caps]

		// It's possible a client asks for a pipeline that's already been created.
		// That's fine.
		(pack.state == nil) or_continue

		is_opaque := .Translucent not_in caps
		vs, ps := gfx_rect_caps_specs(caps)

		target_blend_state: d3d12.RENDER_TARGET_BLEND_DESC = {
			BlendEnable           = !is_opaque,
			LogicOpEnable         = false,
			SrcBlend              = .ONE,
			DestBlend             = .INV_SRC_ALPHA,
			BlendOp               = .ADD,
			SrcBlendAlpha         = .ONE,
			DestBlendAlpha        = .ZERO, // .INV_SRC_ALPHA,
			BlendOpAlpha          = .ADD,
			LogicOp               = .NOOP,
			RenderTargetWriteMask = u8(d3d12.COLOR_WRITE_ENABLE_ALL),
		}
		blend_state: d3d12.BLEND_DESC = {
			AlphaToCoverageEnable = false,
			IndependentBlendEnable = false,
			RenderTarget = {0 = target_blend_state},
		}
		desc: d3d12.GRAPHICS_PIPELINE_STATE_DESC = {
			pRootSignature = gfx_state.root_sig,
			VS = shaders.rect_vs(vs),
			PS = shaders.rect_ps(ps),
			BlendState = blend_state,
			SampleMask = 0xFFFFFFFF,
			RasterizerState = {
				FillMode = .SOLID,
				CullMode = .BACK,
				FrontCounterClockwise = false,
				DepthBias = 0,
				DepthBiasClamp = 0,
				SlopeScaledDepthBias = 0,
				DepthClipEnable = false,
				MultisampleEnable = false,
				AntialiasedLineEnable = false,
				ForcedSampleCount = 0,
				ConservativeRaster = .OFF,
			},
			DepthStencilState = {
				DepthEnable = true,
				DepthWriteMask = is_opaque ? .ALL : .ZERO,
				DepthFunc = .GREATER_EQUAL,
				StencilEnable = false,
				StencilReadMask = d3d12.DEFAULT_STENCIL_READ_MASK,
				StencilWriteMask = d3d12.DEFAULT_STENCIL_WRITE_MASK,
				FrontFace = {.KEEP, .KEEP, .KEEP, .ALWAYS},
				BackFace = {.KEEP, .KEEP, .KEEP, .ALWAYS},
			},
			InputLayout = {pInputElementDescs = raw_data(shader_common_input), NumElements = u32(len(shader_common_input))},
			PrimitiveTopologyType = .TRIANGLE,
			NumRenderTargets = 1,
			RTVFormats = {0 = SWAPCHAIN_FORMAT},
			DSVFormat = DEPTH_STENCIL_FORMAT,
			SampleDesc = {1, 0},
		}

		hr: win.HRESULT
		hr = gfx_state.device->CreateGraphicsPipelineState(&desc, d3d12.IPipelineState_UUID, (^rawptr)(&pack.state))
		checkf(hr, "failed to create graphics pipeline (caps: %#v)", caps)

		sync.atomic_store_explicit(&pack.phase, sync.Futex(Gfx_Pipeline_Phase.Ready), .Release)
		sync.futex_signal(&pack.phase)

		log.debugf("cooked pipeline: caps %#v", caps)
	}
	for pack in gfx_state.pipelines {
		if pack.state != nil {
			pack.state->Release()
		}
	}
}

// This isn't thread safe.
gfx_wait_on_gpu :: proc() {
	hr: win.HRESULT

	for queue in ([?]^d3d12.ICommandQueue{gfx_state.queue}) {
		if queue == nil {continue}

		gfx_state.halt_value += 1

		hr = queue->Signal(gfx_state.halt_fence, gfx_state.halt_value)
		check(hr, "failed to signal halt fence")

		hr = gfx_state.halt_fence->SetEventOnCompletion(gfx_state.halt_value, nil)
		check(hr, "failed to wait on halt fence")
	}
}

// odinfmt: disable
@(private, rodata)
shader_common_input: []d3d12.INPUT_ELEMENT_DESC = {
	{"RECT",  0, .R32G32B32A32_FLOAT, 0, d3d12.APPEND_ALIGNED_ELEMENT, .PER_INSTANCE_DATA, 1},
	{"COLOR", 0, .R8G8B8A8_UNORM,     0, d3d12.APPEND_ALIGNED_ELEMENT, .PER_INSTANCE_DATA, 1},
	{"COLOR", 1, .R8G8B8A8_UNORM,     0, d3d12.APPEND_ALIGNED_ELEMENT, .PER_INSTANCE_DATA, 1},
	{"COLOR", 2, .R8G8B8A8_UNORM,     0, d3d12.APPEND_ALIGNED_ELEMENT, .PER_INSTANCE_DATA, 1},
	{"COLOR", 3, .R8G8B8A8_UNORM,     0, d3d12.APPEND_ALIGNED_ELEMENT, .PER_INSTANCE_DATA, 1},
	{"TEXC",  0, .R32G32B32A32_FLOAT, 0, d3d12.APPEND_ALIGNED_ELEMENT, .PER_INSTANCE_DATA, 1},
	{"PACK",  0, .R32G32B32A32_UINT,  0, d3d12.APPEND_ALIGNED_ELEMENT, .PER_INSTANCE_DATA, 1},
}
// odinfmt: enable

BUFFER_COUNT :: 2
SWAPCHAIN_FLAGS :: dxgi.SWAP_CHAIN{.FRAME_LATENCY_WAITABLE_OBJECT}
SWAPCHAIN_FORMAT :: dxgi.FORMAT.R8G8B8A8_UNORM
DEPTH_STENCIL_FORMAT :: dxgi.FORMAT.D32_FLOAT_S8X24_UINT
DEPTH_STENCIL_CLEAR :: d3d12.DEPTH_STENCIL_VALUE{0, 1}
COLOR_CLEAR :: [4]f32{100.0 / 255, 118.0 / 255, 140.0 / 255, 1.0}

MAX_DRAW_CMDS :: 2048
MAX_DRAW_SPLITS :: 256
Shader_Input :: struct {
	rect:       [4]f32,
	color:      [4][4]u8,
	texc:       [4]f32,
	using pack: struct {
		texi:     u32,
		// TODO: No "using" to avoid compiler bug:
		// 	"llvm_backend_utility.cpp(1133): Assertion Failure: `is_type_pointer(s.type)`".
		// 	393e00bec3e855475659de0c6c38d3898a36cb36.
		inner:    bit_field u32 {
			depth:    u32  | 16,
			border:   u32  | 8,
			round_tl: bool | 1,
			round_tr: bool | 1,
			round_bl: bool | 1,
			round_br: bool | 1,
			glass:    bool | 1,
		},
		corner:   f32,
		softness: f32,
	},
}
Shader_Input_Layout :: [MAX_DRAW_CMDS]Shader_Input

Gfx_Track :: struct {
	buf:        ^d3d12.IResource,
	buf_mapped: ^[BUFFER_COUNT]Shader_Input_Layout,
}

Gfx_Attach :: struct {
	wnd:                win.HWND,
	// Swapchain.
	swapchain:          ^dxgi.ISwapChain3,
	swapchain_rts:      [BUFFER_COUNT]^d3d12.IResource,
	swapchain_waitable: win.HANDLE,
	swapchain_res:      [2]u32,
	// Depth.
	depth_stencil:      ^d3d12.IResource,
	depth_stencil_view: Gfx_Descriptor_Handle(.DSV, 1),
	// Cmds.
	cmd_list:           ^d3d12.IGraphicsCommandList,
	cmd_allocators:     [BUFFER_COUNT]^d3d12.ICommandAllocator,
	// Cmds pt2.
	count_started:      u64, // How many frames have we started rendering?
	count_done:         ^d3d12.IFence, // How many frames have we finished rendering?
	// Cmds pt3.
	track:              Gfx_Track,
	draw_buffer:        [MAX_DRAW_CMDS]Shader_Input,
	draw_count:         int,
	draw_splits:        [MAX_DRAW_SPLITS]bit_field int {
		end:           int  | 63,
		prepare_glass: bool | 1,
	},
	draw_splits_count:  int,
	// TODO: Simplify this.
	offscreen:          [Gfx_Pass_Offscreen]struct {
		texture: ^d3d12.IResource,
		rtv:     Gfx_Descriptor_Handle(.RTV, 1),
		srv:     Gfx_Descriptor_Handle(.CBV_SRV_UAV, 1),
	},
	// Ffx.
	ffx_blur:           Gfx_Ffx_Blur_Context,
	ffx_spd:            Gfx_Ffx_Spd_Context,
}

// TODO: We need to rethink this whole concept. Pathalogical case where size is {0,0} -> no init -> crash..!
gfx_swapchain_hydrate :: proc(a: ^Gfx_Attach, res: [2]i32, $initial: bool) -> (updated: bool) {
	res := linalg.array_cast(res, u32)
	(initial || a.swapchain_res != res) or_return
	a.swapchain_res = res
	(initial || res.x > 0 && res.y > 0) or_return

	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	superluminal.InstrumentationScope("Gfx Swapchain Hydrate", color = GFX_COLOR)

	log.debug("resizing swapchain to:", res)

	// These resources are probably already in use.
	when !initial {
		gfx_wait_on_gpu()
	}

	hr: win.HRESULT

	// Swapchain color.
	if initial {
		desc: dxgi.SWAP_CHAIN_DESC1 = {
			Width       = res.x,
			Height      = res.y,
			Format      = SWAPCHAIN_FORMAT,
			SampleDesc  = {1, 0},
			BufferUsage = {},
			BufferCount = BUFFER_COUNT,
			SwapEffect  = .FLIP_DISCARD,
			AlphaMode   = .IGNORE,
			Flags       = SWAPCHAIN_FLAGS,
			Scaling     = .NONE,
		}

		_swapchain: ^dxgi.ISwapChain1
		hr = gfx_state.dxgi_factory->CreateSwapChainForHwnd(gfx_state.queue, a.wnd, &desc, nil, nil, &_swapchain)
		check(hr, "failed to create swapchain")
		defer _swapchain->Release()

		hr = _swapchain->QueryInterface(dxgi.ISwapChain3_UUID, cast(^rawptr)&a.swapchain)
		check(hr, "failed to upgrade swapchain")

		hr = a.swapchain->SetMaximumFrameLatency(BUFFER_COUNT)
		check(hr, "failed to set swapchain maximum frame latency")

		// TODO: Better support; should use NO_TEARING to get variable refresh when fullscreen.
		hr = gfx_state.dxgi_factory->MakeWindowAssociation(a.wnd, {.NO_ALT_ENTER})
		check(hr, "failed to make window association")

		a.swapchain_waitable = a.swapchain->GetFrameLatencyWaitableObject()
		log.assert(a.swapchain_waitable != win.INVALID_HANDLE, "failed to get swapchian latency waitable object")
	} else {
		for &surface in a.swapchain_rts {
			surface->Release()
		}
		hr = a.swapchain->ResizeBuffers(BUFFER_COUNT, res.x, res.y, SWAPCHAIN_FORMAT, SWAPCHAIN_FLAGS)
		check(hr, "failed to resize swapchain")
	}
	for i in 0 ..< BUFFER_COUNT {
		hr = a.swapchain->GetBuffer(u32(i), d3d12.IResource_UUID, cast(^rawptr)&a.swapchain_rts[i])
		check(hr, "failed to query swapchain surface")

		a.swapchain_rts[i]->SetName(win.utf8_to_wstring(fmt.tprintf("Swapchain Buffer %i", i)))
	}

	// Depth.
	when initial {
		gfx_descriptor_alloc(&a.depth_stencil_view)
	} else {
		a.depth_stencil->Release()
	}
	{
		tex_desc := d3d12.RESOURCE_DESC {
			Dimension        = .TEXTURE2D,
			Width            = u64(res.x),
			Height           = res.y,
			DepthOrArraySize = 1,
			MipLevels        = 1,
			Format           = DEPTH_STENCIL_FORMAT,
			SampleDesc       = {1, 0},
			Layout           = .UNKNOWN,
			Flags            = {.ALLOW_DEPTH_STENCIL, .DENY_SHADER_RESOURCE},
		}

		hr =
		gfx_state.device->CreateCommittedResource(
			&{Type = .DEFAULT},
			{.CREATE_NOT_ZEROED},
			&tex_desc,
			{.DEPTH_WRITE},
			&d3d12.CLEAR_VALUE{Format = tex_desc.Format, DepthStencil = DEPTH_STENCIL_CLEAR},
			d3d12.IResource_UUID,
			(^rawptr)(&a.depth_stencil),
		)
		check(hr, "failed to create depthstencil texture")

		gfx_state.device->CreateDepthStencilView(
			a.depth_stencil,
			&d3d12.DEPTH_STENCIL_VIEW_DESC{Format = tex_desc.Format, ViewDimension = .TEXTURE2D},
			gfx_descriptor_cpu(a.depth_stencil_view),
		)
	}

	// Offscreen temp buffer.
	mip_count := cast(u16)gfx_mips_for_resolution(a.swapchain_res)
	for &pack, type in a.offscreen {
		when initial {
			gfx_descriptor_alloc(&pack.rtv)
			gfx_descriptor_alloc(&pack.srv)
		} else {
			pack.texture->Release()
		}

		switch type {
		case .Render:
			hr =
			gfx_state.device->CreateCommittedResource(
				&{Type = .DEFAULT},
				{},
				&{
					Dimension = .TEXTURE2D,
					Width = u64(res.x),
					Height = res.y,
					DepthOrArraySize = 1,
					MipLevels = 1,
					Format = SWAPCHAIN_FORMAT,
					SampleDesc = {1, 0},
					Layout = .UNKNOWN,
					Flags = {.ALLOW_RENDER_TARGET, .ALLOW_UNORDERED_ACCESS},
				},
				{.RENDER_TARGET},
				&{Format = SWAPCHAIN_FORMAT, Color = COLOR_CLEAR},
				d3d12.IResource_UUID,
				(^rawptr)(&pack.texture),
			)
		case .Working:
			hr =
			gfx_state.device->CreateCommittedResource(
				&{Type = .DEFAULT},
				{},
				&{
					Dimension = .TEXTURE2D,
					Width = u64(res.x),
					Height = res.y,
					DepthOrArraySize = 1,
					MipLevels = mip_count,
					Format = SWAPCHAIN_FORMAT,
					SampleDesc = {1, 0},
					Layout = .UNKNOWN,
					Flags = {.ALLOW_UNORDERED_ACCESS},
				},
				{.PIXEL_SHADER_RESOURCE},
				nil,
				d3d12.IResource_UUID,
				(^rawptr)(&pack.texture),
			)
		case .Downsample:
			hr =
			gfx_state.device->CreateCommittedResource(
				&{Type = .DEFAULT},
				{},
				&{
					Dimension = .TEXTURE2D,
					Width = u64(res.x),
					Height = res.y,
					DepthOrArraySize = 1,
					MipLevels = mip_count,
					Format = SWAPCHAIN_FORMAT,
					SampleDesc = {1, 0},
					Layout = .UNKNOWN,
					Flags = {.ALLOW_UNORDERED_ACCESS},
				},
				{.PIXEL_SHADER_RESOURCE},
				nil,
				d3d12.IResource_UUID,
				(^rawptr)(&pack.texture),
			)
		}
		check(hr, "failed to create temp texture")

		pack.texture->SetName(win.utf8_to_wstring(fmt.tprintf("Offscreen render buffer %s", type)))

		if type == .Render {
			handle := gfx_descriptor_cpu(pack.rtv)
			gfx_state.device->CreateRenderTargetView(pack.texture, nil, handle)
		}
		if type == .Downsample {
			handle := gfx_descriptor_cpu(pack.srv)
			gfx_state.device->CreateShaderResourceView(pack.texture, nil, handle)
		}
	}

	return true
}

gfx_attach :: proc(wnd: win.HWND, allocator := context.allocator) -> ^Gfx_Attach {
	superluminal.InstrumentationScope("Gfx Attach", color = GFX_COLOR)

	attach := new(Gfx_Attach, allocator)
	attach.wnd = wnd

	hr: win.HRESULT
	{
		hr = gfx_state.device->CreateFence(0, nil, d3d12.IFence_UUID, (^rawptr)(&attach.count_done))
		check(hr, "failed to create cmd array fence")
	}
	{
		type := d3d12.COMMAND_LIST_TYPE.DIRECT

		hr = gfx_state.device->CreateCommandList1(0, type, nil, d3d12.ICommandList_UUID, (^rawptr)(&attach.cmd_list))
		check(hr, "failed to create command list")
		for &allocator in attach.cmd_allocators {
			hr = gfx_state.device->CreateCommandAllocator(type, d3d12.ICommandAllocator_UUID, (^rawptr)(&allocator))
			check(hr, "failed to create command allocator")
		}
	}
	{
		hr =
		gfx_state.device->CreateCommittedResource(
			&{Type = .UPLOAD},
			{.CREATE_NOT_ZEROED},
			&{
				Dimension = .BUFFER,
				Width = BUFFER_COUNT * size_of(Shader_Input_Layout),
				Height = 1,
				DepthOrArraySize = 1,
				MipLevels = 1,
				SampleDesc = {1, 0},
				Layout = .ROW_MAJOR,
			},
			d3d12.RESOURCE_STATE_COMMON,
			nil,
			d3d12.IResource_UUID,
			(^rawptr)(&attach.track.buf),
		)
		check(hr, "failed to create input buffer")

		hr = attach.track.buf->Map(0, &d3d12.RANGE{0, 0}, (^rawptr)(&attach.track.buf_mapped))
		check(hr, "failed to map input buffer")
	}

	gfx_ffx_blur_make(&attach.ffx_blur)
	gfx_ffx_spd_make(&attach.ffx_spd)

	return attach
}

gfx_detach :: proc(a: ^Gfx_Attach, allocator := context.allocator) {
	gfx_wait_on_gpu()

	for pack in a.offscreen {
		pack.texture->Release()
		gfx_descriptor_free(pack.rtv)
		gfx_descriptor_free(pack.srv)
	}

	a.track.buf->Release()

	gfx_ffx_blur_destroy(&a.ffx_blur)
	gfx_ffx_spd_destroy(&a.ffx_spd)

	for v in a.swapchain_rts {v->Release()}
	a.swapchain->Release()

	a.depth_stencil->Release()
	a.cmd_list->Release()
	for v in a.cmd_allocators {v->Release()}
	a.count_done->Release()

	win.CloseHandle(a.swapchain_waitable)
	free(a, allocator)
}

gfx_render :: proc(a: ^Gfx_Attach) {
	// TODO: We can skip rendering when our framebuffer is zero-sized, but we MUST always present.
	hr: win.HRESULT

	bb_idx := a.swapchain->GetCurrentBackBufferIndex()
	bb_rt := a.swapchain_rts[bb_idx]

	// Wait for rendering commands concerning this backbuffer to complete.
	a.count_started += 1
	if sync := max(BUFFER_COUNT, a.count_started) - BUFFER_COUNT; a.count_done->GetCompletedValue() < sync {
		hr = a.count_done->SetEventOnCompletion(sync, nil)
		check(hr, "failed to wait on n-buffering fence")
	}

	// "Cannot reset a command allocator while the GPU may be executing a command list stored in the memory associated with the command allocator".
	// "Command lists can be reset immediately after calling ExecuteCommandLists"
	// https://stackoverflow.com/questions/34991725/does-it-make-sense-to-create-an-allocator-per-rendertarget-in-the-swapchain.
	hr = a.cmd_allocators[bb_idx]->Reset()
	check(hr, "failed to reset command allocator")
	hr = a.cmd_list->Reset(a.cmd_allocators[bb_idx], nil)
	check(hr, "failed to reset command list")

	// "SetDescriptorHeaps must be called first.."
	// https://microsoft.github.io/DirectX-Specs/d3d/HLSL_SM_6_6_DynamicResources.html#setdescriptorheaps-and-setrootsignature.
	a.cmd_list->SetDescriptorHeaps(1, &gfx_descriptor.heaps[.CBV_SRV_UAV].resource)

	// TODO: Where do we want to put this?
	glyph_pass_cook(a.cmd_list, bb_idx)
	glyph_draw()

	res := a.swapchain_res
	viewport := d3d12.VIEWPORT{0, 0, f32(res.x), f32(res.y), 0, 1}
	scissor_rect := d3d12.RECT{0, 0, i32(res.x), i32(res.y)}
	a.cmd_list->RSSetViewports(1, &viewport)
	a.cmd_list->RSSetScissorRects(1, &scissor_rect)

	color_view := gfx_descriptor_cpu(a.offscreen[.Render].rtv)
	depth_stencil_view := gfx_descriptor_cpu(a.depth_stencil_view)

	color_clear := COLOR_CLEAR
	a.cmd_list->OMSetRenderTargets(1, &color_view, win.TRUE, &depth_stencil_view)
	a.cmd_list->ClearRenderTargetView(color_view, &color_clear, 0, nil)

	gfx_ffx_blur_frame(&a.ffx_blur, bb_idx)
	gfx_ffx_spd_frame(&a.ffx_spd, bb_idx)

	// Coalesce draws.
	gfx_rect_split(a, prepare_glass = false)
	defer a.draw_count = 0
	defer a.draw_splits_count = 0
	{
		a.cmd_list->SetGraphicsRootSignature(gfx_state.root_sig)

		constants: struct #packed {
			viewport:     [2]f32,
			viewport_inv: [2]f32,
			accum_idx:    u32,
		}

		constants.viewport = {f32(a.swapchain_res.x), f32(a.swapchain_res.y)}
		constants.viewport_inv = 1 / constants.viewport
		constants.accum_idx = cast(u32)gfx_descriptor_idx(a.offscreen[.Downsample].srv)

		a.cmd_list->SetGraphicsRoot32BitConstants(0, size_of(constants) / size_of(u32), &constants, 0)
	}
	{
		a.cmd_list->IASetPrimitiveTopology(.TRIANGLESTRIP)
		view: d3d12.VERTEX_BUFFER_VIEW = {
			StrideInBytes  = size_of(Shader_Input_Layout) / len(Shader_Input_Layout),
			BufferLocation = a.track.buf->GetGPUVirtualAddress() + u64(bb_idx) * size_of(Shader_Input_Layout),
			SizeInBytes    = size_of(Shader_Input_Layout),
		}
		a.cmd_list->IASetVertexBuffers(0, 1, &view)
	}
	{
		// Ensure these are ready before we do anything.
		gfx_pipeline_wait(GFX_RECT_CAPS_OPAQUE)
		gfx_pipeline_wait(GFX_RECT_CAPS_UBER)
	}

	// Opaque rendering is back-to-front, to take advantage of the depth buffer.
	// A neat side effect is that we can use just one buffer!
	// In-order special rects move from the left, reversed batched rects from the right.
	Gfx_Rect_Stream :: enum {
		Opaque,
		Special,
	}
	stream_starts: [Gfx_Rect_Stream]int

	i := 0
	for split in a.draw_splits[:a.draw_splits_count] {
		a.cmd_list->ClearDepthStencilView(depth_stencil_view, {.DEPTH}, DEPTH_STENCIL_CLEAR.Depth, DEPTH_STENCIL_CLEAR.Stencil, 0, nil)

		stream_ends := stream_starts
		defer stream_starts = stream_ends

		Gfx_Special_Batch :: struct {
			caps: Gfx_Rect_Caps,
			end:  int,
		}
		special_splits: [dynamic]Gfx_Special_Batch
		special_splits.allocator = context.temp_allocator
		special_split_curr: Gfx_Special_Batch

		for i < split.end {
			defer i += 1

			#no_bounds_check draw_cmd := a.draw_buffer[i]
			draw_cmd.inner.depth = u32(i)

			caps := gfx_rect_caps_from_cmd(draw_cmd)
			track: Gfx_Rect_Stream = (caps == GFX_RECT_CAPS_OPAQUE) ? .Opaque : .Special

			index := (track == .Special) ? stream_ends[track] : (MAX_DRAW_CMDS - 1 - stream_ends[track])
			a.track.buf_mapped[bb_idx][index] = draw_cmd
			stream_ends[track] += 1

			if track == .Special {
				if special_split_curr.caps != {} && special_split_curr.caps != caps {
					append(&special_splits, special_split_curr)
				}
				special_split_curr = {caps, stream_ends[track]}
			}
		}

		append(&special_splits, special_split_curr)

		// Render opaque rects first.
		draw_opaque: {
			count := stream_ends[.Opaque] - stream_starts[.Opaque]
			(count > 0) or_break draw_opaque

			pipeline := gfx_pipeline_expect(GFX_RECT_CAPS_OPAQUE)

			a.cmd_list->SetPipelineState(pipeline)
			a.cmd_list->DrawInstanced(4, u32(count), 0, MAX_DRAW_CMDS - u32(stream_ends[.Opaque]))
		}

		// Render special rects front-to-back.
		last_split_end := stream_starts[.Special]
		draw_special: for split in special_splits {
			defer last_split_end = split.end

			count := split.end - last_split_end
			(count > 0) or_break draw_special

			pipeline := gfx_pipeline_query(split.caps) or_else gfx_pipeline_expect(GFX_RECT_CAPS_UBER)

			a.cmd_list->SetPipelineState(pipeline)
			a.cmd_list->DrawInstanced(4, u32(count), 0, u32(last_split_end))
		}

		// Prepare blurred textures for sampling in the glass shader.
		(split.prepare_glass) or_continue
		// Downsample colour output buffer.
		{
			barriers := [?]d3d12.RESOURCE_BARRIER {
				{
					Type = .TRANSITION,
					Transition = {a.offscreen[.Render].texture, d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES, {.RENDER_TARGET}, {.NON_PIXEL_SHADER_RESOURCE}},
				},
				{
					Type = .TRANSITION,
					Transition = {a.offscreen[.Working].texture, d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES, {.PIXEL_SHADER_RESOURCE}, {.UNORDERED_ACCESS}},
				},
			}
			a.cmd_list->ResourceBarrier(len(barriers), raw_data(&barriers))
		}
		gfx_ffx_spd_mount(&a.ffx_spd, a.cmd_list, a.offscreen[.Render].texture, a.offscreen[.Working].texture)
		// Select a few mips to use for blurring.
		{
			barriers := [?]d3d12.RESOURCE_BARRIER {
				{
					Type = .TRANSITION,
					Transition = {a.offscreen[.Render].texture, d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES, {.NON_PIXEL_SHADER_RESOURCE}, {.RENDER_TARGET}},
				},
				{
					Type = .TRANSITION,
					Transition = {a.offscreen[.Working].texture, d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES, {.UNORDERED_ACCESS}, {.NON_PIXEL_SHADER_RESOURCE}},
				},
				{
					Type = .TRANSITION,
					Transition = {a.offscreen[.Downsample].texture, d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES, {.PIXEL_SHADER_RESOURCE}, {.UNORDERED_ACCESS}},
				},
			}
			a.cmd_list->ResourceBarrier(len(barriers), raw_data(&barriers))
		}
		mip_count := gfx_mips_for_resolution(a.swapchain_res)
		for mip in 1 ..< u32(mip_count) {
			gfx_ffx_blur_mount(&a.ffx_blur, a.cmd_list, a.offscreen[.Working].texture, a.offscreen[.Downsample].texture, mip, mip)
		}
		{
			barriers := [?]d3d12.RESOURCE_BARRIER {
				{
					Type = .TRANSITION,
					Transition = {a.offscreen[.Working].texture, d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES, {.NON_PIXEL_SHADER_RESOURCE}, {.PIXEL_SHADER_RESOURCE}},
				},
				{
					Type = .TRANSITION,
					Transition = {a.offscreen[.Downsample].texture, d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES, {.UNORDERED_ACCESS}, {.PIXEL_SHADER_RESOURCE}},
				},
			}
			a.cmd_list->ResourceBarrier(len(barriers), raw_data(&barriers))
		}
	}

	// Copy from staging render target to swapchain buffer.
	{
		barriers := [?]d3d12.RESOURCE_BARRIER {
			{Type = .TRANSITION, Transition = {a.offscreen[.Render].texture, d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES, {.RENDER_TARGET}, {.COPY_SOURCE}}},
			{Type = .TRANSITION, Transition = {bb_rt, d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES, d3d12.RESOURCE_STATE_PRESENT, {.COPY_DEST}}},
		}
		a.cmd_list->ResourceBarrier(len(barriers), raw_data(&barriers))
	}
	{
		copy_src: d3d12.TEXTURE_COPY_LOCATION
		copy_src.pResource = a.offscreen[.Render].texture
		copy_src.Type = .SUBRESOURCE_INDEX
		copy_src.SubresourceIndex = 0

		copy_dst: d3d12.TEXTURE_COPY_LOCATION
		copy_dst.pResource = bb_rt
		copy_dst.Type = .SUBRESOURCE_INDEX
		copy_dst.SubresourceIndex = 0

		a.cmd_list->CopyTextureRegion(&copy_dst, 0, 0, 0, &copy_src, nil)
	}
	{
		barriers := [?]d3d12.RESOURCE_BARRIER {
			{Type = .TRANSITION, Transition = {a.offscreen[.Render].texture, d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES, {.COPY_SOURCE}, {.RENDER_TARGET}}},
			{Type = .TRANSITION, Transition = {bb_rt, d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES, {.COPY_DEST}, d3d12.RESOURCE_STATE_PRESENT}},
		}
		a.cmd_list->ResourceBarrier(len(barriers), raw_data(&barriers))
	}

	hr = a.cmd_list->Close()
	check(hr, "failed to close command list")

	gfx_state.queue->ExecuteCommandLists(1, (^^d3d12.ICommandList)(&a.cmd_list))

	// TODO: Recreate renderer if hr is "DXGI_ERROR_DEVICE_REMOVED" or DXGI_ERROR_DEVICE_RESET; IDevice->GetDeviceRemovedReason().
	{
		params: dxgi.PRESENT_PARAMETERS
		hr = a.swapchain->Present1(1, {.RESTART}, &params)
		check(hr, "present failed")
	}

	hr = gfx_state.queue->Signal(a.count_done, a.count_started)
	check(hr, "failed to instruct frame fence signal")
}

// Get the index of the CPU-facing staging buffer to write into.
// TODO: This impl is slow for no good reason.
gfx_buffer_idx :: proc(attach: ^Gfx_Attach) -> int {
	if attach.swapchain != nil {
		return cast(int)attach.swapchain->GetCurrentBackBufferIndex()
	} else {
		return 0
	}
}

// https://vulkan-tutorial.com/Generating_Mipmaps#page_Image-creation.
gfx_mips_for_resolution :: #force_inline proc "contextless" (size: [2]$T) -> int where intrinsics.type_is_integer(T) {
	return cast(int)bits.log2(linalg.max(size)) + 1
}

// Required pipline capabilities to draw this rectangle.
Gfx_Rect_Cap :: enum {
	Texture,
	Rounded,
	Border,
	Glass,
	Translucent,
}
Gfx_Rect_Caps :: bit_set[Gfx_Rect_Cap;u8]
GFX_RECT_CAPS_OPAQUE :: Gfx_Rect_Caps{}
GFX_RECT_CAPS_UBER :: ~Gfx_Rect_Caps{}
GFX_RECT_CAP_PERMS :: 1 << len(Gfx_Rect_Cap)

// Convert caps into shader permutations.
gfx_rect_caps_specs :: proc(caps: Gfx_Rect_Caps) -> (vs: shaders.Rect_Vs_Spec, ps: shaders.Rect_Ps_Spec) {
	if .Texture in caps {
		vs.texture = .Yes
		ps.texture = .Yes
	}
	if .Rounded in caps {
		vs.rounded = .Yes
		ps.rounded = .Yes
	}
	if .Border in caps {
		vs.border = .Yes
		ps.border = .Yes
	}
	if .Glass in caps {
		ps.glass = .Yes
	}
	return
}

gfx_rect_caps_from_cmd :: proc(input: Shader_Input) -> (caps: Gfx_Rect_Caps) {
	if input.texi != max(u32) {
		// We assume the worst case: that all textured rects are translucent. They may not be!
		caps += {.Texture, .Translucent}
	}
	if input.corner > 0 {
		caps += {.Rounded, .Translucent}
	}
	if input.inner.border > 0 {
		caps += {.Border, .Translucent}
	}
	if input.inner.glass {
		caps += {.Glass}
	}
	if input.color[0][3] < 255 || input.color[1][3] < 255 || input.color[2][3] < 255 || input.color[3][3] < 255 {
		caps += {.Translucent}
	}
	return
}

gfx_rect_split :: proc(attach: ^Gfx_Attach, prepare_glass := true) {
	defer attach.draw_splits_count += 1
	attach.draw_splits[attach.draw_splits_count] = {
		end           = attach.draw_count,
		prepare_glass = prepare_glass,
	}
}

gfx_rect_reserve :: proc(attach: ^Gfx_Attach, count: int) -> []Shader_Input {
	defer attach.draw_count += count
	return attach.draw_buffer[attach.draw_count:attach.draw_count + count]
}

gfx_rect_props :: proc(
	slot: ^Shader_Input,
	off: [2]f32,
	dim: [2]f32,
	color: [4]f32,
	texc := [4]f32{},
	texi := max(u32),
	rounding: f32 = 0,
	hardness: f32 = 1,
	border: u32 = 0,
	rounding_corners: [4]bool = true,
	glass := false,
) {
	color := linalg.array_cast(color * 255, u8)

	slot.rect = {off.x, dim.x, off.y, dim.y}
	slot.color[0] = color
	slot.color[1] = color
	slot.color[2] = color
	slot.color[3] = color
	slot.texc = texc
	slot.texi = texi
	slot.corner = rounding
	slot.softness = hardness
	slot.inner.round_tl = rounding_corners[0]
	slot.inner.round_tr = rounding_corners[1]
	slot.inner.round_bl = rounding_corners[2]
	slot.inner.round_br = rounding_corners[3]
	slot.inner.border = border
	slot.inner.glass = glass
}

gfx_rect_null :: proc(slot: ^Shader_Input) {
	// We want to clear this to the simplest possible rectangle to draw.
	// This means opaque (no special shader combinatrics).
	slot^ = {}
}

gfx_attach_draw :: proc(
	attach: ^Gfx_Attach,
	off: [2]f32,
	dim: [2]f32,
	color: [4]f32,
	texc := [4]f32{},
	texi := max(u32),
	rounding: f32 = 0,
	hardness: f32 = 1,
	border: u32 = 0,
	rounding_corners: [4]bool = true,
	glass := false,
) {
	reserve := gfx_rect_reserve(attach, 1)
	gfx_rect_props(raw_data(reserve), off, dim, color, texc, texi, rounding, hardness, border, rounding_corners, glass)
}
