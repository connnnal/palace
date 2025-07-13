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
	trailing_hit, is_inside: win.BOOL,
	text:                    Text_Layout_State,
	hot:                     f32,
}
im_widget_textbox_bind :: proc(node: ^Im_Node, w: ^Window, dt: f32) -> ^Im_Widget_Textbox {
	this, is_new := im_widget_replace(node, Im_Widget_Textbox)

	if is_new {
		this.builder = strings.builder_make(im_state.allocator)

		// Note "text_edit.setup_once" sets a pointer.
		// We can't allow widgets to relocate in memory.
		text_edit.init(&this.box, im_state.allocator, im_state.allocator)
		text_edit.setup_once(&this.box, &this.builder)
	}

	text_edit.update_time(&this.box)

	it: int
	for v in wind_events_next(&it, w) {
		#partial switch inner in v.value {
		case u32:
			defer wind_events_pop(&it)
			handle_key_input(&this.box, inner, v.modifiers)
		case rune:
			defer wind_events_pop(&it)
			handle_char_input(&this.box, inner)
		case In_Click:
			(inner.down && inner.button == .Left) or_continue
			layout := text_state_get_valid_layout(&this.text) or_continue

			metrics: d2w.DWRITE_HIT_TEST_METRICS
			hr := layout->HitTestPoint(f32(inner.pos.x - node.measure.pos.x), f32(inner.pos.y - node.measure.pos.y), &this.trailing_hit, &this.is_inside, &metrics)
			win.SUCCEEDED(hr) or_continue
			defer wind_events_pop(&it)

			blip_loc := metrics.textPosition + (this.trailing_hit ? 1 : 0)
			this.box.selection = {int(blip_loc), int(blip_loc)}
		}
	}

	str := strings.to_string(this.builder)
	text_state_hydrate(&this.text, Text_Desc{.Body, .THIN, .ITALIC, 96, str})
	if len(str) > 0 {
		text_state_cache(&this.text, {f32(node.measure.size.x), f32(node.measure.size.y)})
	}

	im_hot(node.measure, w.mouse, dt, &this.hot)

	node.style.size = {1.0, 256}
	node.color = {0, 0, 0.5 + 0.5 * this.hot, 1}

	return this
}
im_widget_textbox_destroy :: proc(this: ^Im_Widget_Textbox) {
	text_edit.destroy(&this.box)
	strings.builder_destroy(&this.builder)
	text_state_destroy(&this.text)
}
im_widget_textbox_draw :: proc(render: Render, node: ^Im_Node, this: ^Im_Widget_Textbox) {
	im_widget_none_draw(render, node)

	rect := d2w.D2D_RECT_F {
		f32(node.measure.pos.x),
		f32(node.measure.pos.y),
		f32(node.measure.size.x + node.measure.pos.x),
		f32(node.measure.size.y + node.measure.pos.y),
	}
	render.target->PushAxisAlignedClip(&rect, .PER_PRIMITIVE)
	defer render.target->PopAxisAlignedClip()

	hr: win.HRESULT
	select: {
		layout := text_state_get_valid_layout(&this.text) or_break select

		selection := this.box.selection
		selection_low, selection_high := text_edit.sorted_selection(&this.box)

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

	str := strings.to_string(this.builder)
	layout, layout_ok := text_state_get_valid_layout(&this.text)
	text: if len(str) > 0 && layout_ok {
		point := d2w.D2D_POINT_2F{f32(node.measure.pos.x), f32(node.measure.pos.y)}
		render.brush->SetColor(auto_cast &{1, 1, 1, 1})
		render.target->DrawTextLayout(point, layout, render.brush, d2w.D2D1_DRAW_TEXT_OPTIONS{.ENABLE_COLOR_FONT})
	} else {
		im_widget_none_draw(render, node)
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
im_widget_button_draw :: proc(render: Render, node: ^Im_Node, this: ^Im_Widget_Button) {
}

// Text.
Im_Widget_Text :: struct {
	text: Text_Layout_State,
}
im_widget_text_bind :: proc(node: ^Im_Node, desc: Text_Desc) {
	this, _ := im_widget_replace(node, Im_Widget_Text)

	text_state_hydrate(&this.text, desc)

	node.style.size = {nil, nil}
	node.style.measure_func = proc(node: ^Ly_Node, available: [2]Ly_Length) -> [2]i32 {
		node := cast(^Im_Node)node
		this := node.wrapper.(^Im_Widget_Text)

		available := [2]f32{f32(available.x), f32(available.y)}
		layout, ok := text_state_cache(&this.text, available)
		metrics: d2w.DWRITE_TEXT_METRICS

		if ok {
			// Fear not! DWrite metrics are lazily evaluated.
			// Updating props can trigger a slow or fast path, depending on their type.
			// I.e. max dimensions is free; text break sizes from the previous layout control invalidation.
			hr := layout->GetMetrics(&metrics)
			check(hr, "failed to get text metrics")
		}

		return {i32(metrics.width), i32(metrics.height)}
	}
}
im_widget_text_draw :: proc(render: Render, node: ^Im_Node, this: ^Im_Widget_Text) {
	// im_widget_none_draw(render, node)

	text: {
		layout := text_state_get_valid_layout(&this.text) or_break text
		point := d2w.D2D_POINT_2F{f32(node.measure.pos.x), f32(node.measure.pos.y)}
		render.brush->SetColor(auto_cast &p[.Text])
		render.target->DrawTextLayout(point, layout, render.brush, d2w.D2D1_DRAW_TEXT_OPTIONS{.ENABLE_COLOR_FONT})
	}
}
im_widget_text_destroy :: proc(this: ^Im_Widget_Text) {
	text_state_destroy(&this.text)
}

// Default (no widget).
im_widget_none_draw :: proc(render: Render, node: ^Im_Node) {
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
}

Im_Wrapper :: union {
	^Im_Widget_Textbox,
	^Im_Widget_Button,
	^Im_Widget_Text,
}

// We just need a struct with the max size/alignment for each widget type.
// Previously I used an untyped buffer with attributes derived from "max(T)".
// This output bogus values, seemingly because of a compiler bug.
Im_Wrapper_Anon :: struct #raw_union {
	_: Im_Widget_Textbox,
	_: Im_Widget_Button,
	_: Im_Widget_Text,
}

// TODO: Replace this if we get a statically typed "union typeid" intrinsic.
// This is cheaper than the dynamic "reflect.get_union_variant_*" methods.
im_widget_dyn_type :: proc(p: Im_Wrapper) -> typeid {
	switch v in p {
	case ^Im_Widget_Textbox:
		return type_of(v)
	case ^Im_Widget_Button:
		return type_of(v)
	case ^Im_Widget_Text:
		return type_of(v)
	case:
		return nil
	}
}

im_widget_dyn_destroy :: proc(p: Im_Wrapper) {
	switch v in p {
	case ^Im_Widget_Textbox:
		im_widget_textbox_destroy(v)
	case ^Im_Widget_Button:
		im_widget_button_destroy(v)
	case ^Im_Widget_Text:
		im_widget_text_destroy(v)
	}
}

im_widget_dyn_draw :: proc(node: ^Im_Node, p: Im_Wrapper, render: Render) {
	switch v in p {
	case nil:
		// This is the most common case.
		// Hopefully it's first in the jump table.
		im_widget_none_draw(render, node)
	case ^Im_Widget_Textbox:
		im_widget_textbox_draw(render, node, v)
	case ^Im_Widget_Button:
		im_widget_button_draw(render, node, v)
	case ^Im_Widget_Text:
		im_widget_text_draw(render, node, v)
	}
}

@(private = "file")
im_widget_replace :: proc(node: ^Im_Node, $T: typeid) -> (out: ^T, created: bool) {
	existing := node.wrapper
	existing_t := im_widget_dyn_type(existing)

	if existing_t != typeid_of(^T) {
		if existing_t != nil {
			im_widget_dyn_destroy(existing)
			// Unions are data followed by tag. This cast is safe.
			va.free_item(&im_state.widgets, (cast(^^Im_Wrapper_Anon)&existing)^)
		}

		buf, _ := va.alloc(&im_state.widgets)
		out = cast(^T)buf
		node.wrapper = out
		created = true
	} else {
		// As above, cast is safe.
		out = (cast(^^T)&existing)^
	}

	return
}
