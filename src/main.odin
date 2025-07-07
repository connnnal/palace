package main

import "base:runtime"
import "core:log"
import "core:math"
import "core:math/rand"
import "core:time"

import win "core:sys/windows"
import d2w "lib:odin_d2d_dwrite"

main :: proc() {
	context = default_context()

	w: Window
	w.paint_callback = paint_callback

	paint_callback :: proc(w: ^Window, area: [2]i32) {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

		hr: win.HRESULT

		im_frame_begin(&w.im)
		defer im_frame_end(&w.im)

		brushes: [Palette]^d2w.ID2D1SolidColorBrush
		for &b, i in brushes {
			color: d2w.D2D1_COLOR_F
			switch i {
			case .Background:
				color = {100.0 / 255, 118.0 / 255, 140.0 / 255, 1}
			case .Foreground:
				color = {1, 0, 0, 1}
			case .Text:
				color = {0, 1, 0, 1}
			case .Content:
				color = {0, 0, 1, 1}
			}

			IDENTITY := transmute(d2w.D2D_MATRIX_3X2_F)[6]f32{1, 0, 0, 1, 0, 0}
			hr := w.render_target->CreateSolidColorBrush(&color, &{1.0, IDENTITY}, &b)
			check(hr, "failed to create brush")
		}
		defer for b in brushes {
			b->Release()
		}

		when true {
			root: ^Im_Node
			if root = im_scope(id("root"), {size = {1.0, nil}, flow = .Col, color = .Background}); true {
				if root := im_scope(id("header"), {size = {1.0, 64}, flow = .Row, color = .Text}); true {

				}
				if root := im_scope(id("content"), {flow = .Col, gap = 8, padding = {32, 32}, color = .Foreground}); true {
					for i in 0 ..< 4 {
						im_leaf(id("child", i), {size = {32, 32}, color = .Content})
					}
					im_leaf(id("foo"), {size = {0.3, 100}, color = .Content})
				}
			}
			im_recurse(root, area)

			log.info("\n", im_dump(root))

			clear(&w.im.draws)
			im_state_draws(&w.im, root)
		}

		w.render_target->BeginDraw()

		for v in w.im.draws {
			w.render_target->FillRectangle(
				&d2w.D2D_RECT_F{f32(v.measure.pos.x), f32(v.measure.pos.y), f32(v.measure.size.x + v.measure.pos.x), f32(v.measure.size.y + v.measure.pos.y)},
				brushes[v.color],
			)
		}

		D2DERR_RECREATE_TARGET :: transmute(win.HRESULT)u32(0x8899000C)
		defer {
			hr := w.render_target->EndDraw(nil, nil)
			if hr == D2DERR_RECREATE_TARGET {
				// TODO: Recreate render target and resource.
			}
			check(hr, "failed to end draw")
		}
	}

	wind_open(&w)
	defer wind_close(&w)

	for {
		free_all(context.temp_allocator)

		wind_pump(&w) or_break
		wind_paint(&w)
	}
}
