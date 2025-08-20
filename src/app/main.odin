package main

import "core:fmt"
import "core:log"
import "core:math/rand"

import win "core:sys/windows"
import "lib:superluminal"

import "src:common"
check :: common.check
checkf :: common.checkf
default_context :: common.default_context

APP_NAME :: "Palace"

Render :: struct {
	attach: ^Gfx_Attach,
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

	superluminal.InstrumentationScope("Main", color = superluminal.MAKE_COLOR(0, 255, 0))

	w: Window
	w.update_callback = update_callback
	w.paint_callback = paint_callback

	@(static) frame: int

	update_callback :: proc(w: ^Window, area: [2]i32, dt: f32) {
		superluminal.InstrumentationScope("Update", color = superluminal.MAKE_COLOR(0, 0, 255))

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
						textbox_node := im_leaf(id("box"), {color = p[.Content]})
						textbox := im_widget_textbox_bind(textbox_node, w, dt)

						for i in 0 ..< 10 {
							(frame % 50 < 10) or_break
							node := im_leaf(id("child", i), {size = {32, 32}, color = p[.Content]})
							im_widget_text_bind(node, {.Body, .SEMI_BOLD, .NORMAL, 16 + i32((frame + i) % 4), fmt.tprintf("hi!!! %v", frame)})
						}
						{
							node := im_leaf(id("foo4"), {color = p[.Content]})
							im_widget_text_bind(node, {.Special, .SEMI_BOLD, .NORMAL, 64, "hiya!!!!!!!!!!!!!!!!!!!!!!!"})
						}
						{
							node := im_leaf(id("foo5"), {color = p[.Content]})
							im_widget_text_bind(node, {.Special, .SEMI_BOLD, .NORMAL, 32, "0123456789"})
						}
						// im_leaf(id("foo2"), {color = p[.Midground], text = Text_Desc{.Body, .SEMI_BOLD, .NORMAL, 128, "ooooooooooooo"}})
						// im_leaf(id("foo3"), {color = p[.Midground], text = Text_Desc{.Special, .SEMI_BOLD, .NORMAL, 32, "okay"}})
					}
					if root := im_scope(id("inner"), {flow = .Col, gap = 8, padding = 64, grow = true, align_items = .FlexStart, color = p[.Foreground]}); true {
						// im_leaf(id("foo2"), {color = p[.Midground], text = Text_Desc{.Body, .SEMI_BOLD, .NORMAL, 128, "ooooooooooooo"}})
						// im_leaf(id("foo3"), {color = p[.Midground], text = Text_Desc{.Special, .SEMI_BOLD, .NORMAL, 32, "okay"}})
						// im_leaf(
						// 	id("foo"),
						// 	{color = p[.Foreground], text = Text_Desc{.Body, .SEMI_BOLD, .NORMAL, 128 + i32(frame % 4) * 8, "let's do some word wrapping! :^)"}},
						// )

						if node := im_scope(id("button"), {padding = {32, 16}, color = p[.Void]}); true {
							im_widget_button_bind(node, w, dt)

							node := im_leaf(id("foo4"), {color = p[.Content]})
							im_widget_text_bind(node, {.Special, .BLACK, .NORMAL, 24, "click me"})
						}
					}
				}
			}

			im_draws(&w.im, root)
		}

		// TODO: Not a correct solution.
		if area.x > 0 && area.y > 0 {
			im_recurse(root, area)
		}

		// Drain any uncollected inputs.
		it: int
		for _ in wind_events_next(&it, w) {
			wind_events_pop(&it)
		}
	}
	paint_callback :: proc(w: ^Window) {
		superluminal.InstrumentationScope("Paint", color = superluminal.MAKE_COLOR(255, 0, 0))

		// TODO: I dislike this here. Paint should have no knowledge of the simulation.
		im_ctx_enter(&w.im)
		defer im_ctx_exit(&w.im)

		render := Render{w.attach}

		for v in w.im.draws {
			im_widget_dyn_draw(render, v, v.wrapper)
		}

		gfx_attach_draw(render.attach, {128, 64 + 16}, {512, 128 * 5}, {1, 0, 1, 1}, {}, rounding = 32, rounding_corners = {true, true, true, true}, test = true)
	}

	wind_open(&w)
	defer wind_close(&w)

	for {
		wind_pump(&w) or_break
	}
}
