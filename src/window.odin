package main

import "core:log"

import win "core:sys/windows"
import d2w "lib:odin_d2d_dwrite"


// https://learn.microsoft.com/en-us/windows/win32/direct2d/improving-direct2d-performance.
// https://learn.microsoft.com/en-us/archive/msdn-magazine/2013/may/windows-with-c-introducing-direct2d-1-1#connecting-the-device-context-and-swap-chain.
// https://raphlinus.github.io/personal/2018/04/08/smooth-resize.html.
// https://learn.microsoft.com/en-us/windows/win32/direct2d/devices-and-device-contexts.

CLASS_NAME :: APP_NAME + "Main"

wind_state: struct {
	instance: win.HINSTANCE,
	factory:  ^d2w.ID2D1Factory5,
}

Window :: struct #no_copy {
	wnd:            win.HWND,
	render_target:  ^d2w.ID2D1HwndRenderTarget,
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

			this.render_target->Resize(&{u32(this.area.x), u32(this.area.y)})

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
		hr = d2w.D2D1CreateFactory(
			.MULTI_THREADED,
			d2w.ID2D1Factory5_UUID,
			&d2w.D2D1_FACTORY_OPTIONS{ODIN_DEBUG ? .INFORMATION : .NONE},
			(^rawptr)(&wind_state.factory),
		)
		check(hr, "failed to init window")
	}
}

@(fini)
wind_shutdown :: proc "contextless" () {
	wind_state.factory->Release()
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

	hr: win.HRESULT

	hr =
	wind_state.factory->CreateHwndRenderTarget(
		&d2w.D2D1_RENDER_TARGET_PROPERTIES{},
		&d2w.D2D1_HWND_RENDER_TARGET_PROPERTIES{hwnd = w.wnd, pixelSize = {WIDTH, HEIGHT}},
		&w.render_target,
	)
	check(hr, "failed to create hwnd render target")

	win.ShowWindow(w.wnd, win.SW_NORMAL)

	return true
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
	(w.render_target->CheckWindowState() == .NONE) or_return

	w.paint_callback(w, w.area)

	return true
}

wind_close :: proc(w: ^Window) {
	w.render_target->Release()
	win.DestroyWindow(w.wnd)
	im_state_destroy(&w.im)
}
