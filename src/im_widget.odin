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

// Textbox.
Im_Widget_Textbox :: struct #no_copy {
	box:                     text_edit.State,
	builder:                 strings.Builder,
	hit:                     Maybe(d2w.DWRITE_HIT_TEST_METRICS),
	trailing_hit, is_inside: win.BOOL,
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
}
im_widget_textbox_update :: proc(w: ^Window, state: ^Im_State, node: ^Im_Node, wg: ^Im_Widget_Textbox, dt: f32) {
	text_edit.update_time(&wg.box)

	it: int
	for v in wind_events_next(&it, nil) {
		#partial switch inner in v.value {
		case rune:
			defer wind_events_pop(&it)
			handle_char_input(&wg.box, inner)
		case In_Click:
			(inner.down && inner.button == .Left) or_continue
			layout := text_state_get_valid_layout(&node.text) or_continue

			metrics: d2w.DWRITE_HIT_TEST_METRICS
			hr := layout->HitTestPoint(f32(inner.pos.x - node.measure.pos.x), f32(inner.pos.y - node.measure.pos.y), &wg.trailing_hit, &wg.is_inside, &metrics)
			win.SUCCEEDED(hr) or_continue
			defer wind_events_pop(&it)

			wg.hit = metrics

			blip_loc := metrics.textPosition + (wg.trailing_hit ? 1 : 0)
			wg.box.selection = {int(blip_loc), int(blip_loc)}
		}

	}

	im_hot(node.measure, &wg.hot, w.mouse, dt)

	node.color = {0, 0, wg.hot, 1}

	str := strings.to_string(wg.builder)
	if len(str) > 0 {
		text_state_hydrate(&node.text, Text_Desc{.Body, .THIN, .ITALIC, 96, str})
	}
}
im_widget_textbox_draw :: proc(wg: ^Im_Widget_Textbox, node: ^Im_Node, render: Render) {
	select: {
		layout := text_state_get_valid_layout(&node.text) or_break select

		selection := wg.box.selection

		selection_low, selection_high := text_edit.sorted_selection(&wg.box)
		hit_test: [8]d2w.DWRITE_HIT_TEST_METRICS
		hit_test_count: u32
		hr := layout->HitTestTextRange(
			u32(selection_low),
			u32(selection_high),
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
			render.render_target->FillRectangle(&rect, render.brush)
		}

		if hit, ok := wg.hit.?; ok {
			pos := [2]f32{f32(node.measure.pos.x), f32(node.measure.pos.y)}
			metrics: d2w.DWRITE_HIT_TEST_METRICS
			hr := layout->HitTestTextPosition(hit.textPosition, wg.trailing_hit, &pos[0], &pos[1], &metrics)
			win.SUCCEEDED(hr) or_break select

			render.brush->SetColor(auto_cast &{1, 1, 0, 1})

			metrics.left += f32(node.measure.pos.x)
			metrics.top += f32(node.measure.pos.y)
			rect := d2w.D2D_RECT_F{metrics.left, metrics.top, metrics.left + metrics.width, metrics.top + metrics.height}
			render.render_target->FillRectangle(&rect, render.brush)
		}

		if hit, ok := wg.hit.?; ok {
			blip_loc := hit.textPosition + (wg.trailing_hit ? 1 : 0)

			pos := [2]f32{f32(node.measure.pos.x), f32(node.measure.pos.y)}
			metrics: d2w.DWRITE_HIT_TEST_METRICS
			hr := layout->HitTestTextPosition(blip_loc, wg.trailing_hit, &pos[0], &pos[1], &metrics)
			win.SUCCEEDED(hr) or_break select

			render.brush->SetColor(auto_cast &{0, 1, 0, 1})

			metrics.left += f32(node.measure.pos.x)
			metrics.top += f32(node.measure.pos.y)
			rect := d2w.D2D_RECT_F{metrics.left, metrics.top, metrics.left + 4, metrics.top + metrics.height}
			render.render_target->FillRectangle(&rect, render.brush)
		}
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
im_widget_dyn_type :: proc(p: Im_Wrapper) -> (typeid, rawptr) {
	switch v in p {
	case ^Im_Widget_Textbox:
		return type_of(v), v
	case ^Im_Widget_Button:
		return type_of(v), v
	case:
		return nil, nil
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

im_widget_dyn_draw :: proc(node: ^Im_Node, p: Im_Wrapper, r: Render) {
	#partial switch v in p {
	case ^Im_Widget_Textbox:
		im_widget_draw(v, node, r)
	}
}

im_widget_hydrate :: proc(w: ^Window, state: ^Im_State, node: ^Im_Node, $T: typeid, dt: f32) -> (out: ^T) {
	existing := node.wrapper
	existing_t, existing_p := im_widget_dyn_type(existing)
	has_existing := existing != nil

	if has_existing && existing_t != typeid_of(^T) {
		im_widget_dyn_destroy(existing)
	}
	if !has_existing || existing_t != typeid_of(^T) {
		buf, idx := va.alloc(&state.widgets)
		out = cast(^T)buf

		node.wrapper = out
		im_widget_create(state, out)
	} else {
		out = cast(^T)existing_p
	}

	im_widget_update(w, state, node, out, dt)

	return
}
