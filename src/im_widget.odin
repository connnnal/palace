package main

import "base:intrinsics"
import "base:runtime"
import "core:log"
import "core:strings"
import text_edit "core:text/edit"

import win "core:sys/windows"
import d2w "lib:odin_d2d_dwrite"
import va "lib:virtual_array"

handle_char_input :: proc(box: ^text_edit.State, codepoint: rune) {
	switch codepoint {
	case 32 ..= 126:
		text_edit.input_rune(box, codepoint)
	case 8:
		// Backspace.
		text_edit.perform_command(box, .Backspace)
	case 127:
		// Ctrl+backspace.
		text_edit.perform_command(box, .Delete_Word_Left)
	case 27:
		// Escape.
		// TODO: Handle exiting focus.
		break
	case 1:
		// Ctrl+A.
		text_edit.perform_command(box, .Select_All)
	case 26:
		// Ctrl+Z.
		text_edit.perform_command(box, .Undo)
	case 25:
		// Ctrl+Y.
		text_edit.perform_command(box, .Redo)
	case 3:
		// Ctrl+C.
		text_edit.perform_command(box, .Copy)
	case 22:
		// Ctrl+V.
		text_edit.perform_command(box, .Paste)
	case 24:
		// Ctrl+X.
		text_edit.perform_command(box, .Cut)
	}
}

handle_key_input :: proc(box: ^text_edit.State, key: u32, modifiers: In_Modifiers) {
	switch key {
	case win.VK_LEFT:
		switch modifiers & {.Ctrl, .Shift} {
		case {}:
			text_edit.perform_command(box, .Left)
		case {.Ctrl}:
			text_edit.perform_command(box, .Word_Left)
		case {.Shift}:
			text_edit.perform_command(box, .Select_Left)
		case {.Ctrl, .Shift}:
			text_edit.perform_command(box, .Select_Word_Left)
		}
	case win.VK_RIGHT:
		switch modifiers & {.Ctrl, .Shift} {
		case {}:
			text_edit.perform_command(box, .Right)
		case {.Ctrl}:
			text_edit.perform_command(box, .Word_Right)
		case {.Shift}:
			text_edit.perform_command(box, .Select_Right)
		case {.Ctrl, .Shift}:
			text_edit.perform_command(box, .Select_Word_Right)
		}
	case win.VK_UP:
		// TODO: Needs awareness of text layout.
		text_edit.perform_command(box, .Up)
	case win.VK_DOWN:
		// TODO: Needs awareness of text layout.
		text_edit.perform_command(box, .Down)
	}
}

// Textbox.
Im_Widget_Textbox :: struct #no_copy {
	box:                     text_edit.State,
	builder:                 strings.Builder,
	hit:                     Maybe(d2w.DWRITE_HIT_TEST_METRICS),
	trailing_hit, is_inside: win.BOOL,
	text:                    Maybe(Text_Layout_State),
	hot:                     f32,
}
im_widget_textbox_create :: proc(state: ^Im_State, w: ^Im_Widget_Textbox) {
	w.builder = strings.builder_make(state.allocator)

	// Note "text_edit.setup_once" sets a pointer.
	// We can't allow widgets to relocate in memory.
	text_edit.init(&w.box, state.allocator, state.allocator)
	text_edit.setup_once(&w.box, &w.builder)
}
im_widget_textbox_destroy :: proc(w: ^Im_Widget_Textbox) {
	text_edit.destroy(&w.box)
	strings.builder_destroy(&w.builder)
	text_state_destroy(&w.text)
}
im_widget_textbox_update :: proc(w: ^Window, state: ^Im_State, node: ^Im_Node, wg: ^Im_Widget_Textbox, dt: f32) {
	text_edit.update_time(&wg.box)

	it: int
	for v in wind_events_next(&it, w) {
		#partial switch inner in v.value {
		case u32:
			defer wind_events_pop(&it)
			handle_key_input(&wg.box, inner, v.modifiers)
		case rune:
			defer wind_events_pop(&it)
			handle_char_input(&wg.box, inner)
		case In_Click:
			(inner.down && inner.button == .Left) or_continue
			layout := text_state_get_valid_layout(&wg.text) or_continue

			metrics: d2w.DWRITE_HIT_TEST_METRICS
			hr := layout->HitTestPoint(f32(inner.pos.x - node.measure.pos.x), f32(inner.pos.y - node.measure.pos.y), &wg.trailing_hit, &wg.is_inside, &metrics)
			win.SUCCEEDED(hr) or_continue
			defer wind_events_pop(&it)

			blip_loc := metrics.textPosition + (wg.trailing_hit ? 1 : 0)
			wg.box.selection = {int(blip_loc), int(blip_loc)}
		}
	}

	str := strings.to_string(wg.builder)
	text_state_hydrate(&wg.text, Text_Desc{.Body, .THIN, .ITALIC, 96, str})
	if len(str) > 0 {
		text_state_cache(&wg.text, {f32(node.measure.size.x), f32(node.measure.size.y)})
	}

	im_hot(node.measure, &wg.hot, w.mouse, dt)

	node.color = {0, 0, 0.5 + 0.5 * wg.hot, 1}
}
im_widget_textbox_draw :: proc(wg: ^Im_Widget_Textbox, node: ^Im_Node, render: Render) {
	hr: win.HRESULT
	select: {
		layout := text_state_get_valid_layout(&wg.text) or_break select

		selection := wg.box.selection
		selection_low, selection_high := text_edit.sorted_selection(&wg.box)

		// Drag box.
		if selection_low != selection_high {
			hit_test: [8]d2w.DWRITE_HIT_TEST_METRICS
			hit_test_count: u32
			hr =
			layout->HitTestTextRange(
				u32(selection_low),
				u32(selection_high - selection_low),
				f32(node.measure.pos.x),
				f32(node.measure.pos.y),
				raw_data(&hit_test),
				len(hit_test),
				&hit_test_count,
			)
			win.SUCCEEDED(hr) or_break select

			for test in hit_test[:hit_test_count] {
				rect := d2w.D2D_RECT_F{test.left, test.top, test.left + test.width, test.top + test.height}
				render.brush->SetColor(auto_cast &{1, 0, 1, 1})
				render.target->FillRectangle(&rect, render.brush)
			}
		}

		// Position blip.
		{
			// TODO: What does "isTrailingHit" even do here??
			pos := [2]f32{f32(node.measure.pos.x), f32(node.measure.pos.y)}
			metrics: d2w.DWRITE_HIT_TEST_METRICS
			hr = layout->HitTestTextPosition(u32(selection[0]), win.FALSE, &pos[0], &pos[1], &metrics)
			win.SUCCEEDED(hr) or_break select

			render.brush->SetColor(auto_cast &{0, 1, 0, 1})

			metrics.left += f32(node.measure.pos.x)
			metrics.top += f32(node.measure.pos.y)
			rect := d2w.D2D_RECT_F{metrics.left, metrics.top, metrics.left + 4, metrics.top + metrics.height}
			render.target->FillRectangle(&rect, render.brush)
		}
	}

	str := strings.to_string(wg.builder)
	layout, layout_ok := text_state_get_valid_layout(&wg.text)
	text: if len(str) > 0 && layout_ok {
		im_widget_none_draw(node, render, false)

		rect := d2w.D2D_RECT_F {
			f32(node.measure.pos.x),
			f32(node.measure.pos.y),
			f32(node.measure.size.x + node.measure.pos.x),
			f32(node.measure.size.y + node.measure.pos.y),
		}

		render.target->PushAxisAlignedClip(&rect, .PER_PRIMITIVE)

		point := d2w.D2D_POINT_2F{f32(node.measure.pos.x), f32(node.measure.pos.y)}
		render.brush->SetColor(auto_cast &p[.Text])
		render.target->DrawTextLayout(point, layout, render.brush, d2w.D2D1_DRAW_TEXT_OPTIONS{.ENABLE_COLOR_FONT})

		render.target->PopAxisAlignedClip()
	} else {
		im_widget_none_draw(node, render, true)
	}

}

// Button.
Im_Widget_Button :: struct {
	click: bool,
}
im_widget_button_create :: proc(state: ^Im_State, w: ^Im_Widget_Button) {
}
im_widget_button_destroy :: proc(w: ^Im_Widget_Button) {
}
im_widget_button_update :: proc(w: ^Window, state: ^Im_State, node: ^Im_Node, wg: ^Im_Widget_Button, dt: f32) {
}

// Default (no widget).
im_widget_none_draw :: proc(node: ^Im_Node, render: Render, use_text := true) {
	rect := d2w.D2D_RECT_F {
		f32(node.measure.pos.x),
		f32(node.measure.pos.y),
		f32(node.measure.size.x + node.measure.pos.x),
		f32(node.measure.size.y + node.measure.pos.y),
	}
	render.brush->SetColor(auto_cast &node.color)
	if node.color == p[.Background] {
		render.target->FillRectangle(&rect, render.brush)
		render.target->FillRectangle(&rect, render.bmp)
	} else {
		render.target->FillRectangle(&rect, render.brush)
	}

	text: if use_text {
		layout := text_state_get_valid_layout(&node.text) or_break text

		point := d2w.D2D_POINT_2F{f32(node.measure.pos.x), f32(node.measure.pos.y)}
		render.brush->SetColor(auto_cast &p[.Text])
		render.target->DrawTextLayout(point, layout, render.brush, d2w.D2D1_DRAW_TEXT_OPTIONS{.ENABLE_COLOR_FONT})
	}
}

im_widget_create :: proc {
	im_widget_textbox_create,
	im_widget_button_create,
}
im_widget_update :: proc {
	im_widget_textbox_update,
	im_widget_button_update,
}
im_widget_destroy :: proc {
	im_widget_textbox_destroy,
	im_widget_button_destroy,
}
im_widget_draw :: proc {
	im_widget_textbox_draw,
	im_widget_none_draw,
}

Im_Wrapper :: union {
	^Im_Widget_Textbox,
	^Im_Widget_Button,
}

// We just need a struct with the max size/alignment for each widget type.
// Previously I used an untyped buffer with attributes derived from "max(T)".
// This output bogus values, seemingly because of a compiler bug.
Im_Wrapper_Anon :: struct #raw_union {
	_: Im_Widget_Textbox,
	_: Im_Widget_Button,
}

// TODO: Replace this if we get a statically typed "union typeid" intrinsic.
im_widget_dyn_type :: proc(p: Im_Wrapper) -> typeid {
	switch v in p {
	case ^Im_Widget_Textbox:
		return type_of(v)
	case ^Im_Widget_Button:
		return type_of(v)
	case:
		return nil
	}
}

im_widget_dyn_destroy :: proc(p: Im_Wrapper) {
	switch v in p {
	case ^Im_Widget_Textbox:
		im_widget_destroy(v)
	case ^Im_Widget_Button:
		im_widget_destroy(v)
	}
}

im_widget_dyn_draw :: proc(node: ^Im_Node, p: Im_Wrapper, render: Render) {
	#partial switch v in p {
	case ^Im_Widget_Textbox:
		im_widget_draw(v, node, render)
	case:
		im_widget_none_draw(node, render)
	}
}

im_widget_hydrate :: proc(w: ^Window, state: ^Im_State, node: ^Im_Node, $T: typeid, dt: f32) -> (out: ^T) {
	existing := node.wrapper
	existing_t := im_widget_dyn_type(existing)

	if existing_t != typeid_of(^T) {
		if existing_t != nil {
			im_widget_dyn_destroy(existing)
		}

		buf, _ := va.alloc(&state.widgets)
		out = cast(^T)buf
		node.wrapper = out

		im_widget_create(state, out)
	} else {
		// Unions are data followed by tag. This cast is safe.
		out = (cast(^^T)&existing)^
	}

	im_widget_update(w, state, node, out, dt)

	return
}
