package main

import "core:log"
import "core:time"
import "core:unicode/utf8"

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
	events:   [dynamic]In_Event,
}

In_Modifier :: enum {
	Shift,
	Ctrl,
	Alt,
}
In_Modifiers :: bit_set[In_Modifier]

In_Button :: enum {
	Left,
	Right,
	Middle,
}

In_Click :: struct {
	down:   bool,
	button: In_Button,
}

In_Event :: struct {
	w:         ^Window,
	modifiers: In_Modifiers,
	value:     union {
		rune,
		In_Click,
	},
}

Window :: struct #no_copy {
	wnd:            win.HWND,
	render_target:  ^d2w.ID2D1HwndRenderTarget,
	paint_callback: proc(w: ^Window, area: [2]i32, dt: f32),
	area:           [2]i32,
	im:             Im_State,
	high_surrogate: Maybe(win.WCHAR),
	modifiers:      In_Modifiers,
	mouse:          Maybe([2]i32),
	mouse_tracking: win.BOOL,
	last_paint:     time.Tick,
}

@(init)
wind_init :: proc "contextless" () {
	context = default_context()

	hr: win.HRESULT

	wind_state.instance = win.HINSTANCE(win.GetModuleHandleW(nil))
	log.assert(wind_state.instance != nil, "failed to get instance")

	wind_state.events.allocator = context.allocator

	wc: win.WNDCLASSEXW
	callback :: proc "system" (wnd: win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) -> win.LRESULT {
		context = default_context()

		this := transmute(^Window)win.GetWindowLongPtrW(wnd, win.GWLP_USERDATA)

		msg_opt: switch msg {
		case win.WM_CREATE:
			create_params := transmute(^win.CREATESTRUCTW)lparam
			this := transmute(win.LONG_PTR)create_params.lpCreateParams
			win.SetWindowLongPtrW(wnd, win.GWLP_USERDATA, this)
		case win.WM_KEYDOWN:
			switch wparam {
			case win.VK_ESCAPE:
				win.DestroyWindow(wnd)
			case win.VK_SHIFT:
				this.modifiers |= {.Shift}
			case win.VK_CONTROL:
				this.modifiers |= {.Ctrl}
			case win.VK_MENU:
				this.modifiers |= {.Alt}
			case:
				break msg_opt
			}
			return 0
		case win.WM_KEYUP:
			switch wparam {
			case win.VK_SHIFT:
				this.modifiers &= ~{.Shift}
			case win.VK_CONTROL:
				this.modifiers &= ~{.Ctrl}
			case win.VK_MENU:
				this.modifiers &= ~{.Alt}
			case:
				break msg_opt
			}
			return 0
		case win.WM_MOUSEMOVE:
			this.mouse = [2]i32{win.GET_X_LPARAM(lparam), win.GET_Y_LPARAM(lparam)}
			if !this.mouse_tracking {
				// TODO: Shouldn't spam call this. Also, fragile with multiple windows.
				this.mouse_tracking = win.TrackMouseEvent(&{size_of(win.TRACKMOUSEEVENT), win.TME_LEAVE, wnd, win.HOVER_DEFAULT})
			}
		case win.WM_LBUTTONDOWN, win.WM_LBUTTONUP, win.WM_RBUTTONDOWN, win.WM_RBUTTONUP:
			click: In_Click
			switch msg {
			case win.WM_LBUTTONDOWN:
				click.down = true
				fallthrough
			case win.WM_LBUTTONUP:
				click.button = .Left
			case win.WM_RBUTTONDOWN:
				click.down = true
				fallthrough
			case win.WM_RBUTTONUP:
				click.button = .Right
			}

			this.mouse = [2]i32{win.GET_X_LPARAM(lparam), win.GET_Y_LPARAM(lparam)}
			append(&wind_state.events, In_Event{this, this.modifiers, click})
		case win.WM_MOUSELEAVE:
			this.mouse = nil
			this.mouse_tracking = win.FALSE
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
		case win.WM_CHAR:
			wchar := win.WCHAR(wparam)
			if wparam >= 0xd800 && wparam <= 0xdbff {
				// https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-char#remarks.
				// High surrogate. Store for joining to next mesage.
				this.high_surrogate = wchar
			} else {
				defer this.high_surrogate = nil

				buf_w: [3]win.WCHAR
				if high_surrogate, ok := this.high_surrogate.?; ok {
					buf_w = {high_surrogate, wchar, 0}
				} else {
					buf_w = {wchar, 0, 0}
				}

				buf_utf8: [4]u8
				str := win.wstring_to_utf8(buf_utf8[:], raw_data(&buf_w))

				if r, len := utf8.decode_rune_in_bytes(buf_utf8[:]); r != utf8.RUNE_ERROR {
					append(&wind_state.events, In_Event{this, this.modifiers, r})
					return 0
				}
			}
		case win.WM_DROPFILES:
			// TODO: Accept files, dropped links.
			drop := transmute(win.HDROP)wparam
			count := win.DragQueryFileW(drop, 0xFFFFFFFF, nil, win.MAX_PATH)
			return 0
		case win.WM_SYSCOMMAND:
			switch wparam {
			case win.SC_KEYMENU:
				// Disable Alt+ popup menus.
				// https://stackoverflow.com/q/11623085
				// https://learn.microsoft.com/en-us/windows/win32/menurc/wm-syscommand.
				return 0
			}
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

	dt: f32
	if last := w.last_paint; last != {} {
		w.last_paint = time.tick_now()

		diff := time.tick_diff(last, w.last_paint)
		dt = cast(f32)time.duration_seconds(diff)
	}

	w.paint_callback(w, w.area, dt)

	return true
}

wind_close :: proc(w: ^Window) {
	w.render_target->Release()
	win.DestroyWindow(w.wnd)
	im_state_destroy(&w.im)
}

wind_events_next :: proc(it: ^int, w: ^Window = nil) -> (^In_Event, bool) {
	#no_bounds_check for it^ < len(wind_state.events) {
		defer it^ += 1
		input := &wind_state.events[it^]
		(w == nil || input.w == w) or_continue
		return input, true
	}
	return nil, false
}

wind_events_pop :: proc(it: ^int, loc := #caller_location) {
	it^ -= 1
	ordered_remove(&wind_state.events, it^, loc)
}
