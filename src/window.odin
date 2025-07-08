package main

import "core:flags"
import "core:log"

import win "core:sys/windows"
import d2w "lib:odin_d2d_dwrite"
import d3d11 "vendor:directx/d3d11"
import dxgi "vendor:directx/dxgi"

// https://learn.microsoft.com/en-us/windows/win32/direct2d/improving-direct2d-performance.
// https://learn.microsoft.com/en-us/archive/msdn-magazine/2013/may/windows-with-c-introducing-direct2d-1-1#connecting-the-device-context-and-swap-chain.
// https://raphlinus.github.io/personal/2018/04/08/smooth-resize.html.
// https://learn.microsoft.com/en-us/windows/win32/direct2d/devices-and-device-contexts.

// https://github.com/gfx-rs/wgpu/issues/5374.
// https://raphlinus.github.io/rust/gui/2019/06/21/smooth-resize-test.html.

CLASS_NAME :: APP_NAME + "Main"

wind_state: struct {
	instance:       win.HINSTANCE,
	factory:        ^d2w.ID2D1Factory5,
	d2d_device:     ^d2w.ID2D1Device,
	d2d_device_ctx: ^d2w.ID2D1DeviceContext,
	dxgi_device:    ^dxgi.IDevice1,
	dxgi_adapter:   ^dxgi.IAdapter,
	dxgi_factory:   ^dxgi.IFactory2,
	device:         ^d3d11.IDevice,
	device_ctx:     ^d3d11.IDeviceContext,
}

Window :: struct #no_copy {
	wnd:            win.HWND,
	swapchain:      ^dxgi.ISwapChain1,
	backbuffer:     ^d2w.ID2D1Bitmap1,
	paint_callback: proc(w: ^Window, area: [2]i32),
	area:           [2]i32,
	im:             Im_State,
}

@(init)
wind_init :: proc "contextless" () {
	context = default_context()

	hr: win.HRESULT

	wind_state.instance = win.HINSTANCE(win.GetModuleHandleW(nil))
	log.assert(wind_state.instance != nil, "failed to get instance")

	wc: win.WNDCLASSEXW
	callback :: proc "system" (wnd: win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) -> win.LRESULT {
		context = default_context()

		this := transmute(^Window)win.GetWindowLongPtrW(wnd, win.GWLP_USERDATA)

		switch msg {
		case win.WM_CREATE:
			create_params := transmute(^win.CREATESTRUCTW)lparam
			this := transmute(win.LONG_PTR)create_params.lpCreateParams
			win.SetWindowLongPtrW(wnd, win.GWLP_USERDATA, this)
		case win.WM_KEYDOWN:
			if (wparam == win.VK_ESCAPE) {
				win.DestroyWindow(wnd)
				return 0
			}
		case win.WM_SIZE:
			(this != nil) or_break

			c_rect: win.RECT
			win.GetClientRect(wnd, &c_rect) or_break
			this.area = {c_rect.right - c_rect.left, c_rect.bottom - c_rect.top}

			wind_hydrate_swapchain(this)

			fallthrough
		case win.WM_PAINT:
			(this != nil) or_break

			wind_paint(this)

			return 0
		case win.WM_DROPFILES:
			// TODO: Accept files, dropped links.
			drop := transmute(win.HDROP)wparam
			count := win.DragQueryFileW(drop, 0xFFFFFFFF, nil, win.MAX_PATH)
			log.info("drop", count)
			return 0
		case win.WM_DESTROY:
			win.PostQuitMessage(0)
			return 0
		}
		return win.DefWindowProcW(wnd, msg, wparam, lparam)
	}
	wc = win.WNDCLASSEXW {
		cbSize        = size_of(wc),
		style         = win.CS_HREDRAW | win.CS_VREDRAW,
		lpfnWndProc   = callback,
		hInstance     = wind_state.instance,
		hIcon         = win.LoadIconA(nil, win.IDI_APPLICATION),
		hCursor       = win.LoadCursorA(nil, win.IDC_ARROW),
		hbrBackground = nil, // win.CreateSolidBrush(win.RGB(255, 0, 0)),
		lpszMenuName  = nil,
		lpszClassName = win.L(CLASS_NAME),
		hIconSm       = nil,
	}
	class := win.RegisterClassExW(&wc)
	log.assert(class != 0, "failed to register window class")

	{
		creation_flags: d3d11.CREATE_DEVICE_FLAGS = {.BGRA_SUPPORT} | {.DEBUG} when ODIN_DEBUG else {}
		feature_levels := [?]d3d11.FEATURE_LEVEL{._11_1, ._11_0, ._10_1, ._10_0, ._9_3, ._9_2, ._9_1}

		feature_level: d3d11.FEATURE_LEVEL

		hr = d3d11.CreateDevice(
			nil,
			.HARDWARE,
			nil,
			creation_flags,
			raw_data(&feature_levels),
			auto_cast len(feature_levels),
			d3d11.SDK_VERSION,
			&wind_state.device,
			&feature_level,
			&wind_state.device_ctx,
		)
		check(hr, "failed to create d3d11 device")

		hr = wind_state.device->QueryInterface(dxgi.IDevice1_UUID, (^rawptr)(&wind_state.dxgi_device))
		check(hr, "failed to query dxgi device")

		hr = wind_state.dxgi_device->SetMaximumFrameLatency(1)
		check(hr, "failed to set dxgi device maximum frame latency")

		hr = wind_state.dxgi_device->GetAdapter(&wind_state.dxgi_adapter)
		check(hr, "failed to get dxgi adapter")

		hr = wind_state.dxgi_adapter->GetParent(dxgi.IFactory2_UUID, (^rawptr)(&wind_state.dxgi_factory))
		check(hr, "failed to get parent dxgi factory")
	}
	{
		hr = d2w.D2D1CreateFactory(
			.MULTI_THREADED,
			d2w.ID2D1Factory5_UUID,
			&d2w.D2D1_FACTORY_OPTIONS{ODIN_DEBUG ? .INFORMATION : .NONE},
			(^rawptr)(&wind_state.factory),
		)
		check(hr, "failed to init window")

		hr = wind_state.factory->CreateDevice(wind_state.dxgi_device, &wind_state.d2d_device)
		check(hr, "failed to create d2d device")

		hr = wind_state.d2d_device->CreateDeviceContext({}, &wind_state.d2d_device_ctx)
		check(hr, "failed to create d2d device context")
	}
}

@(fini)
wind_shutdown :: proc "contextless" () {
	wind_state.factory->Release()
	wind_state.d2d_device->Release()
	wind_state.d2d_device_ctx->Release()
	wind_state.device->Release()
	wind_state.device_ctx->Release()
	wind_state.dxgi_device->Release()
	wind_state.dxgi_adapter->Release()
}

wind_open :: proc(w: ^Window) -> (ok: bool) {
	im_state_init(&w.im)

	WINDOW_STYLE :: win.WS_OVERLAPPEDWINDOW

	WIDTH :: 1920
	HEIGHT :: 1080

	client_area := win.RECT{0, 0, WIDTH, HEIGHT}
	win.AdjustWindowRect(&client_area, WINDOW_STYLE, win.FALSE)
	w.area = {WIDTH, HEIGHT}

	w.wnd = win.CreateWindowExW(
		win.WS_EX_ACCEPTFILES,
		win.L(CLASS_NAME),
		win.L("Hello world! :^)"),
		WINDOW_STYLE,
		win.CW_USEDEFAULT,
		win.CW_USEDEFAULT,
		client_area.right - client_area.left,
		client_area.bottom - client_area.top,
		nil,
		nil,
		wind_state.instance,
		w,
	)
	log.assert(w.wnd != nil, "failed to create window")

	// Allow this to fail silently, very old versions of Windows 10 may not support it.
	// https://learn.microsoft.com/en-us/windows/apps/desktop/modernize/ui/apply-windows-themes#enable-a-dark-mode-title-bar-for-win32-applications.
	DWMWA_USE_IMMERSIVE_DARK_MODE :: 20
	enable_dark := win.TRUE
	win.DwmSetWindowAttribute(w.wnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &enable_dark, size_of(enable_dark))

	wind_hydrate_swapchain(w)

	win.ShowWindow(w.wnd, win.SW_NORMAL)

	return true
}

@(private)
wind_hydrate_swapchain :: proc(w: ^Window) {
	hr: win.HRESULT

	if w.backbuffer != nil {
		w.backbuffer->Release()
	}

	desc := dxgi.SWAP_CHAIN_DESC1 {
		Width       = u32(w.area.x),
		Height      = u32(w.area.y),
		Format      = .B8G8R8A8_UNORM,
		SampleDesc  = {1, 0},
		BufferUsage = {.RENDER_TARGET_OUTPUT},
		BufferCount = 2,
		Scaling     = .NONE,
		SwapEffect  = .SEQUENTIAL,
		Flags       = {.ALLOW_TEARING, .FRAME_LATENCY_WAITABLE_OBJECT},
	}

	if w.swapchain == nil {
		hr = wind_state.dxgi_factory->CreateSwapChainForHwnd(wind_state.device, w.wnd, &desc, nil, nil, &w.swapchain)
		check(hr, "failed to create hwnd swapchain")
	} else {
		hr = w.swapchain->ResizeBuffers(desc.BufferCount, desc.Width, desc.Height, .UNKNOWN, desc.Flags)
		check(hr, "failed to resize hwnd swapchain")
	}

	{
		DPI :: 1
		bitmap_properties := d2w.D2D1_BITMAP_PROPERTIES1 {
			pixelFormat   = {.B8G8R8A8_UNORM, .IGNORE},
			dpiX          = DPI,
			dpiY          = DPI,
			bitmapOptions = {.TARGET, .CANNOT_DRAW},
		}

		backbuffer: ^dxgi.ISurface
		hr = w.swapchain->GetBuffer(0, dxgi.ISurface_UUID, (^rawptr)(&backbuffer))
		check(hr, "failed to get swapchain backbuffer")
		defer backbuffer->Release()

		hr = wind_state.d2d_device_ctx->CreateBitmapFromDxgiSurface(backbuffer, &bitmap_properties, &w.backbuffer)
		check(hr, "failed to create bitmap from dxgi surface")
	}
}

wind_pump :: proc(w: ^Window) -> (keep_alive: bool = true) {
	for {
		msg: win.MSG
		win.PeekMessageW(&msg, nil, 0, 0, win.PM_REMOVE) or_break

		switch msg.message {
		case win.WM_QUIT:
			keep_alive = false
		case:
			win.TranslateMessage(&msg)
			win.DispatchMessageW(&msg)
		}
	}

	return
}

wind_paint :: proc(w: ^Window) -> (updated: bool) {
	w.paint_callback(w, w.area)
	w.swapchain->Present1(0, {.ALLOW_TEARING, .DO_NOT_WAIT}, &{})
	return true
}

wind_close :: proc(w: ^Window) {
	w.backbuffer->Release()
	w.swapchain->Release()
	win.DestroyWindow(w.wnd)
}
