package main

import "base:runtime"
import "core:log"
import "core:mem"
import "core:time"
import "core:unicode/utf8"

import win "core:sys/windows"

foreign import user32 "system:User32.lib"

@(private, default_calling_convention = "system")
foreign user32 {
	DragDetect :: proc(hwnd: win.HWND, pt: win.POINT) -> win.BOOL ---
}

// https://learn.microsoft.com/en-us/windows/win32/direct2d/improving-direct2d-performance.
// https://learn.microsoft.com/en-us/archive/msdn-magazine/2013/may/windows-with-c-introducing-direct2d-1-1#connecting-the-device-context-and-swap-chain.
// https://raphlinus.github.io/personal/2018/04/08/smooth-resize.html.
// https://learn.microsoft.com/en-us/windows/win32/direct2d/devices-and-device-contexts.

CLASS_NAME :: APP_NAME + "Main"

wind_state: struct {
	instance: win.HINSTANCE,
	events:   [dynamic]In_Event,
	bg:       win.HBRUSH,
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

In_Move :: struct {
	pos: [2]i32,
}

In_Click_Type :: enum {
	Up,
	Down,
	Double,
	Drag_Start,
	Drag_End,
}

In_Click :: struct {
	type:   In_Click_Type,
	button: In_Button,
	pos:    [2]i32,
}

In_Event :: struct {
	w:         ^Window,
	modifiers: In_Modifiers,
	value:     union {
		rune, // Codepoint.
		u32, // Other key.
		In_Click, // Mouse click.
		In_Move, // Mouse move.
	},
}

Window :: struct #no_copy {
	wnd:             win.HWND,
	attach:          ^Gfx_Attach,
	update_callback: proc(w: ^Window, area: [2]i32, dt: f32),
	paint_callback:  proc(w: ^Window),
	last_paint:      time.Tick,
	area:            [2]i32,
	using input:     Window_Input,
	im:              Im_State,
}

Window_Input :: struct #no_copy {
	high_surrogate: win.WCHAR,
	modifiers:      In_Modifiers,
	mouse:          Maybe([2]i32),
	mouse_tracking: win.BOOL,
	enable_drag:    win.BOOL,
	captured:       bool,
}

@(init)
wind_init :: proc "contextless" () {
	context = default_context()

	wind_state.instance = win.HINSTANCE(win.GetModuleHandleW(nil))
	log.assert(wind_state.instance != nil, "failed to get instance")

	wind_state.events.allocator = context.allocator

	wind_state.bg = win.CreateSolidBrush(win.RGB(100, 118, 140))

	wc: win.WNDCLASSEXW
	callback :: proc "system" (wnd: win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) -> win.LRESULT {
		context = default_context()

		if msg == win.WM_CREATE {
			create_params := transmute(^win.CREATESTRUCTW)lparam
			this := transmute(win.LONG_PTR)create_params.lpCreateParams
			win.SetWindowLongPtrW(wnd, win.GWLP_USERDATA, this)
			return 0
		}

		this := transmute(^Window)win.GetWindowLongPtrW(wnd, win.GWLP_USERDATA)
		if this == nil {
			return win.DefWindowProcW(wnd, msg, wparam, lparam)
		}

		msg_opt: switch msg {
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
			case win.VK_LEFT, win.VK_RIGHT, win.VK_UP, win.VK_DOWN, win.VK_DELETE:
				append(&wind_state.events, In_Event{this, this.modifiers, u32(wparam)})
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
			pos := [2]i32{win.GET_X_LPARAM(lparam), win.GET_Y_LPARAM(lparam)}
			this.mouse = pos
			if !this.mouse_tracking {
				// TODO: Shouldn't spam call this. Also, fragile with multiple windows.
				this.mouse_tracking = win.TrackMouseEvent(&{size_of(win.TRACKMOUSEEVENT), win.TME_LEAVE, wnd, win.HOVER_DEFAULT})
			}
			append(&wind_state.events, In_Event{this, this.modifiers, In_Move{pos}})
			return 0
		case win.WM_LBUTTONDOWN, win.WM_LBUTTONUP, win.WM_RBUTTONDOWN, win.WM_RBUTTONUP, win.WM_LBUTTONDBLCLK:
			click: In_Click
			switch msg {
			case win.WM_LBUTTONDBLCLK:
				click.type = .Double
				click.button = .Left
			case win.WM_LBUTTONDOWN:
				click.type = .Down
				click.button = .Left
			case win.WM_LBUTTONUP:
				click.type = .Up
				click.button = .Left
			case win.WM_RBUTTONDBLCLK:
				click.type = .Double
				click.button = .Right
			case win.WM_RBUTTONDOWN:
				click.type = .Down
				click.button = .Right
			case win.WM_RBUTTONUP:
				click.type = .Up
				click.button = .Right
			}

			if msg == win.WM_LBUTTONDOWN && this.enable_drag {
				if DragDetect(wnd, {win.GET_X_LPARAM(lparam), win.GET_Y_LPARAM(lparam)}) {
					this.captured = true
					click.type = .Drag_Start
					win.SetCapture(wnd)
				}
			} else {
				if this.captured && msg == win.WM_LBUTTONUP {
					this.captured = false
					click.type = .Drag_End
					win.ReleaseCapture()
				}
			}

			click.pos = [2]i32{win.GET_X_LPARAM(lparam), win.GET_Y_LPARAM(lparam)}
			this.mouse = click.pos
			append(&wind_state.events, In_Event{this, this.modifiers, click})
			return 0
		case win.WM_MOUSELEAVE:
			this.mouse = nil
			this.mouse_tracking = win.FALSE
			return 0
		case win.WM_SIZE:
			c_rect: win.RECT
			win.GetClientRect(wnd, &c_rect) or_break
			this.area = {c_rect.right - c_rect.left, c_rect.bottom - c_rect.top}

			// BUG: This can be re-entrant wrt. paint!! Faults allocator guard etc. Need to break here.
			return 0
		case win.WM_CHAR, win.WM_IME_CHAR:
			// https://what.thedailywtf.com/topic/27102/how-do-i-allow-input-from-the-windows-10-emoji-panel-in-my-c-application/25.
			wchar := win.WCHAR(wparam)
			if wparam >= 0xd800 && wparam <= 0xdbff {
				// https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-char#remarks.
				// High surrogate. Store for joining to next mesage.
				this.high_surrogate = wchar
			} else {
				// See above, a valid high surrogate is != 0.
				defer this.high_surrogate = {}

				buf_utf16: [2]win.WCHAR
				if this.high_surrogate != {} {
					buf_utf16 = {this.high_surrogate, wchar}
				} else {
					buf_utf16 = {wchar, 0}
				}

				buf_utf8: [4]u8
				str := win.utf16_to_utf8(buf_utf8[:], buf_utf16[:])

				if r, _ := utf8.decode_rune(str); r != utf8.RUNE_ERROR {
					append(&wind_state.events, In_Event{this, this.modifiers, r})
				}
			}
			return 0
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
		style         = win.CS_HREDRAW | win.CS_VREDRAW | win.CS_DBLCLKS,
		lpfnWndProc   = callback,
		hInstance     = wind_state.instance,
		hIcon         = win.LoadIconA(nil, win.IDI_APPLICATION),
		hCursor       = win.LoadCursorA(nil, win.IDC_ARROW),
		hbrBackground = wind_state.bg,
		lpszMenuName  = nil,
		lpszClassName = win.L(CLASS_NAME),
		hIconSm       = nil,
	}
	class := win.RegisterClassExW(&wc)
	log.assert(class != 0, "failed to register window class")
}

@(fini)
wind_shutdown :: proc "contextless" () {
	win.DeleteObject(cast(win.HGDIOBJ)wind_state.bg)
}

wind_open :: proc(w: ^Window) -> (ok: bool) {
	im_state_init(&w.im, context.allocator)

	WINDOW_STYLE :: win.WS_OVERLAPPEDWINDOW

	WIDTH :: 1920
	HEIGHT :: 1080

	outer_area := win.RECT{0, 0, WIDTH, HEIGHT}
	win.AdjustWindowRect(&outer_area, WINDOW_STYLE, win.FALSE)
	w.area = {WIDTH, HEIGHT}

	w.wnd = win.CreateWindowExW(
		win.WS_EX_ACCEPTFILES,
		win.L(CLASS_NAME),
		win.L("Hello world! :^)"),
		WINDOW_STYLE,
		win.CW_USEDEFAULT,
		win.CW_USEDEFAULT,
		outer_area.right - outer_area.left,
		outer_area.bottom - outer_area.top,
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

	w.attach = gfx_attach(w.wnd, context.allocator)
	gfx_swapchain_hydrate(w.attach, w.area, true)

	// TODO: Could defer showing to after first render.
	win.ShowWindow(w.wnd, win.SW_NORMAL)

	return true
}

wind_pump :: proc(w: ^Window) -> (keep_alive: bool = true) {
	res := win.MsgWaitForMultipleObjects(1, &w.attach.swapchain_waitable, win.FALSE, win.INFINITE, win.QS_ALLINPUT)

	switch res {
	case win.WAIT_OBJECT_0:
		wind_step(w)
	case win.WAIT_OBJECT_0 + 1:
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
	case:
		// Unknown error state.
		log.warnf("unknown MsgWaitForMultipleObjects result %v", res)
		keep_alive = false
	}

	return
}

wind_step :: proc(w: ^Window) -> (updated: bool) {
	defer free_all(context.temp_allocator)

	dt: f32
	now := time.tick_now()
	if last := w.last_paint; last != {} {
		diff := time.tick_diff(last, now)
		dt = cast(f32)time.duration_seconds(diff)
	}
	w.last_paint = now

	// Step update.
	{
		// Note that we avoid guarding the temporary allocator here.
		// We may want to reference allocated memory in the paint callback.
		w.enable_drag = false
		w.update_callback(w, w.area, dt)
	}
	// Step painting.
	{
		// There is no subesquent step after this, it's safe to guard the allocator.
		// Ideal as this callback can re-run per "frame".
		// BUG: This crashes on alt+enter then alt+tab; is painting->WM_SIZE re-entrant?
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

		gfx_swapchain_hydrate(w.attach, w.area, false)
		w.paint_callback(w)
		gfx_render(w.attach)
	}

	glyph_end_frame()

	return true
}

wind_close :: proc(w: ^Window) {
	gfx_detach(w.attach)
	win.DestroyWindow(w.wnd)
	im_state_destroy(&w.im)
}

wind_events_next :: proc(it: ^int, w: ^Window = nil) -> (^In_Event, bool) {
	#no_bounds_check for it^ < len(wind_state.events) {
		defer it^ += 1
		input := &wind_state.events[it^]
		// If an input is bound to a window, we must pass that window to view it.
		(input.w == nil || input.w == w) or_continue
		return input, true
	}
	return nil, false
}

wind_events_pop :: proc(it: ^int, loc := #caller_location) {
	it^ -= 1
	ordered_remove(&wind_state.events, it^, loc)
}

wind_clipboard_set :: proc(w: ^Window, text: string) -> (ok: bool) {
	win.OpenClipboard(w.wnd) or_return
	defer win.CloseClipboard()

	text := win.utf8_to_utf16(text, context.temp_allocator)
	(text != nil) or_return

	// The OS takes ownership of this allocation if setting the clipboard succeeds.
	// On failure, we need to free it ourselves.
	alloc := win.GlobalAlloc(win.GMEM_MOVEABLE, (1 + len(text)) * size_of(win.WCHAR))
	(alloc != nil) or_return
	defer if !ok {win.GlobalFree(alloc)}

	global := win.HGLOBAL(alloc)

	ptr := win.GlobalLock(global)
	(ptr != nil) or_return
	defer win.GlobalUnlock(global)

	data := cast([^]u16)ptr
	mem.copy_non_overlapping(data, raw_data(text), len(text) * size_of(win.WCHAR))
	data[len(text)] = 0

	ret := win.SetClipboardData(win.CF_UNICODETEXT, win.HANDLE(alloc))
	(ret != nil) or_return

	return true
}

wind_clipboard_get :: proc(w: ^Window, allocator := context.temp_allocator) -> (text: string, ok: bool) {
	win.OpenClipboard(w.wnd) or_return
	defer win.CloseClipboard()

	win.IsClipboardFormatAvailable(win.CF_UNICODETEXT) or_return

	handle := win.GetClipboardData(win.CF_UNICODETEXT)
	(handle != nil) or_return

	global := win.HGLOBAL(handle)

	ptr := win.GlobalLock(global)
	(ptr != nil) or_return
	defer win.GlobalUnlock(global)

	// Clipboard data is untrusted, cap the length.
	MAX_CLIPBOARD_CHARS :: 4096
	data := cast([^]u16)ptr
	length := 0
	for c in data[:MAX_CLIPBOARD_CHARS] {
		(c > 0) or_break
		length += 1
	}

	str_utf8, allocator_err := win.wstring_to_utf8(win.wstring(ptr), length, allocator)
	return str_utf8, allocator_err == nil
}
