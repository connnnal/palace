package main

import "core:log"
import "core:math"
import "core:time"

import win "core:sys/windows"
import d2w "lib:odin_d2d_dwrite"

main :: proc() {
	context = default_context()

	@(static) time_start: time.Tick
	time_start = time.tick_now()

	paint_callback :: proc(w: ^Window, area: [2]i32) {
		hr: win.HRESULT

		im_frame_begin(&w.im)
		defer im_frame_end(&w.im)

		{
			if root := im_push(id("hello"), Im_Style{size = {{1, 0}, {0, 32}}}); true {
				for i in 0 ..< 20 {
					if child := im_push(id("child", i), Im_Style{size = {{0, 32}, {0, 32}}}); true {

					}
				}
			}
		}

		brush2: ^d2w.ID2D1SolidColorBrush
		hr =
		w.render_target->CreateSolidColorBrush(
			&d2w.D2D1_COLOR_F{0.1, 0.1, 0.1, 1.0},
			&d2w.D2D1_BRUSH_PROPERTIES{1.0, d2w.D2D_MATRIX_3X2_F{Anonymous = {m = {1, 0, 0, 1, 0, 0}}}},
			&brush2,
		)
		check(hr, "failed to create brush")
		defer brush2->Release()

		brush: ^d2w.ID2D1SolidColorBrush
		hr =
		w.render_target->CreateSolidColorBrush(
			&d2w.D2D1_COLOR_F{0.4, 0.5, 0.6, 1.0},
			&d2w.D2D1_BRUSH_PROPERTIES{1.0, d2w.D2D_MATRIX_3X2_F{Anonymous = {m = {1, 0, 0, 1, 0, 0}}}},
			&brush,
		)
		check(hr, "failed to create brush")
		defer brush->Release()

		off := time.tick_since(time_start)
		secs := time.duration_seconds(off)
		sl := math.sin(secs * 2)

		w.render_target->BeginDraw()

		w.render_target->FillRectangle(&d2w.D2D_RECT_F{0, 0, 1920, 1080}, brush)
		w.render_target->FillRectangle(&d2w.D2D_RECT_F{0, 0, f32(area.x), f32(area.y)}, brush2)

		D2DERR_RECREATE_TARGET :: transmute(win.HRESULT)u32(0x8899000C)
		defer {
			hr := w.render_target->EndDraw(nil, nil)
			if hr == D2DERR_RECREATE_TARGET {
				// TODO: Recreate render target and resource.
			}
			check(hr, "failed to end draw")
		}

		for x in 0 ..< 50 {
			w.render_target->FillEllipse(&d2w.D2D1_ELLIPSE{{64 + f32(sl * 32), 64 + f32(x * 64)}, 128, 32}, brush)
		}
	}

	w: Window
	w.paint_callback = paint_callback

	wind_open(&w)
	defer wind_close(&w)

	for {
		free_all(context.temp_allocator)

		wind_pump(&w) or_break
		wind_paint(&w)
	}
}
