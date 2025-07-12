package main

import "base:runtime"
import "core:bytes"
import "core:fmt"
import "core:image"
import "core:image/png"
import "core:log"
import "core:math/rand"
import "core:mem"
import "core:text/match"

import win "core:sys/windows"
import d2w "lib:odin_d2d_dwrite"

Render :: struct {
	render_target: ^d2w.ID2D1RenderTarget,
	brush:         ^d2w.ID2D1SolidColorBrush,
	bmp:           ^d2w.ID2D1BitmapBrush,
}

render_setup :: proc(r: ^Render, rt: ^d2w.ID2D1RenderTarget) {
	rt->AddRef()
	r.render_target = rt

	img := image.load_from_bytes(#load("../rsc/paper-6-TEX.png"), {.alpha_add_if_missing}, context.temp_allocator) or_else log.panic("failed to load image")
	bytes := bytes.buffer_to_bytes(&img.pixels)
	defer image.destroy(img, context.temp_allocator)

	IDENTITY := transmute(d2w.D2D_MATRIX_3X2_F)[6]f32{1, 0, 0, 1, 0, 0}
	hr := rt->CreateSolidColorBrush(&{}, &{1.0, IDENTITY}, &r.brush)
	check(hr, "failed to create brush")

	bitmap: ^d2w.ID2D1Bitmap
	hr =
	rt->CreateBitmap(
		{u32(img.width), u32(img.height)},
		raw_data(bytes),
		u32(img.width) * 4 * size_of(u8),
		&{pixelFormat = {.R8G8B8A8_UNORM, .PREMULTIPLIED}},
		&bitmap,
	)
	check(hr, "failed to create bitmap")
	defer bitmap->Release()

	IDENTITY = transmute(d2w.D2D_MATRIX_3X2_F)([6]f32{1, 0, 0, 1, 0, 0} * 0.28)
	hr = rt->CreateBitmapBrush(bitmap, &{.WRAP, .WRAP, .LINEAR}, &{0.15, IDENTITY}, &r.bmp)
	check(hr, "failed to create bitmap brush")
}

render_reset :: proc(r: ^Render) {
	if r^ != {} {
		r.render_target->Release()
		r.brush->Release()
		r.bmp->Release()
		r^ = {}
	}
}

Palette :: enum {
	Void,
	Background,
	Midground,
	Foreground,
	Content,
	Text,
}

@(rodata)
p: [Palette][4]f32 = {
	.Void       = {100.0 / 255, 118.0 / 255, 140.0 / 255, 1},
	.Background = {0.95, 0.91, 0.89, 1},
	.Midground  = {0.99, 0.98, 0.97, 1},
	.Foreground = {1, 1, 1, 1},
	.Text       = {0, 0.18, 0.14, 1},
	.Content    = {0, 0, 1, 1},
}

main :: proc() {
	context = default_context()

	w: Window
	w.update_callback = update_callback
	w.paint_callback = paint_callback

	@(static) frame: int

	@(static) render: Render
	defer render_reset(&render)

	update_callback :: proc(w: ^Window, area: [2]i32, dt: f32) {
		// Note that we avoid guarding the temporary allocator here.
		// We may want to reference allocated memory in the paint callback.
		defer frame += 1
		frame := frame / 5

		root: ^Im_Node
		{
			im_frame_begin(&w.im)
			defer im_frame_end(&w.im)

			if root = im_scope(id("root"), {size = {1.0, nil}, flow = .Col, color = p[.Midground]}); true {
				if root := im_scope(id("header"), {size = {1.0, 64}, flow = .Row, color = p[.Foreground]}); true {

				}
				if root := im_scope(id("content"), {flow = .Row, gap = 32, padding = 32, color = p[.Background]}); true {
					if root := im_scope(id("sidebar"), {flow = .Col, gap = 8, padding = 32, size = {500, nil}, color = p[.Foreground]}); true {
						// for i in 0 ..< 4_000 {
						// 	(frame % 20 > 10) or_break
						// 	node := im_leaf(
						// 		id("child", i),
						// 		{
						// 			size = {32, 32},
						// 			color = p[.Content],
						// 			text = Text_Desc{.Body, .SEMI_BOLD, .NORMAL, 16 + i32((frame + i) % 4), fmt.tprintf("hi!!! %v", frame)},
						// 		},
						// 	)
						// }
						node := im_leaf(id("foo4"), {color = p[.Content], text = Text_Desc{.Special, .SEMI_BOLD, .NORMAL, 32, "default text"}})
						if true || frame % 60 > 30 {
							_ = im_widget_hydrate(w, &w.im, node, Im_Widget_Textbox)
						} else {
							_ = im_widget_hydrate(w, &w.im, node, Im_Widget_Button)
						}
						im_leaf(id("foo2"), {color = p[.Midground], text = Text_Desc{.Body, .SEMI_BOLD, .NORMAL, 128, "ooooooooooooo"}})
						im_leaf(id("foo3"), {color = p[.Midground], text = Text_Desc{.Special, .SEMI_BOLD, .NORMAL, 32, "okay"}})
					}
					if root := im_scope(id("inner"), {flow = .Col, gap = 8, padding = 64, grow = true, color = p[.Foreground]}); true {
						im_leaf(id("foo2"), {color = p[.Midground], text = Text_Desc{.Body, .SEMI_BOLD, .NORMAL, 128, "ooooooooooooo"}})
						im_leaf(id("foo3"), {color = p[.Midground], text = Text_Desc{.Special, .SEMI_BOLD, .NORMAL, 32, "okay"}})
						im_leaf(
							id("foo"),
							{color = p[.Foreground], text = Text_Desc{.Body, .SEMI_BOLD, .NORMAL, 128 + i32(frame % 4) * 8, "let's do some word wrapping! :^)"}},
						)
					}
				}
			}
		}

		// TODO: Not a correct solution.
		if area.x > 0 && area.y > 0 {
			im_recurse(root, area)
		}
		im_hot(&w.im, w.mouse, dt)

		clear(&w.im.draws)
		im_state_draws(&w.im, root)

		// Drain any uncollected inputs.
		it: int
		for v in wind_events_next(&it, w) {
			wind_events_pop(&it)
		}
	}
	paint_callback :: proc(w: ^Window, recreate: bool) {
		// There is no subesquent step after this, it's safe to guard the allocator.
		// Ideal as this callback can re-run per "frame".
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

		if recreate {
			render_reset(&render)
			render_setup(&render, w.render_target)
		}

		w.render_target->SetTextAntialiasMode(.CLEARTYPE)
		for v in w.im.draws {
			rect := d2w.D2D_RECT_F{f32(v.measure.pos.x), f32(v.measure.pos.y), f32(v.measure.size.x + v.measure.pos.x), f32(v.measure.size.y + v.measure.pos.y)}
			render.brush->SetColor(auto_cast &v.color)
			if v.color == p[.Background] {
				w.render_target->FillRectangle(&rect, render.brush)
				w.render_target->FillRectangle(&rect, render.bmp)
			} else {
				w.render_target->FillRectangle(&rect, render.brush)
			}

			im_widget_dyn_draw(v, v.wrapper, render)

			layout := text_state_get_valid_layout(&v.text) or_continue

			point := d2w.D2D_POINT_2F{f32(v.measure.pos.x), f32(v.measure.pos.y)}
			render.brush->SetColor(auto_cast &p[.Text])
			w.render_target->DrawTextLayout(point, layout, render.brush, d2w.D2D1_DRAW_TEXT_OPTIONS{.ENABLE_COLOR_FONT})
		}
	}

	wind_open(&w)
	defer wind_close(&w)

	for {
		wind_pump(&w) or_break
	}
}
