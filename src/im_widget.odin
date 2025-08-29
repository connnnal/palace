package main

import "base:intrinsics"
import "base:runtime"
import "core:log"
import "core:strings"
import text_edit "core:text/edit"

import win "core:sys/windows"
import d2w "lib:odin_d2d_dwrite"
import va "virtual_array"

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
		// TODO: Exiting here feels really lame.
		im_state.focus = 0
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
	case win.VK_DELETE:
		text_edit.perform_command(box, .Delete)
	}
}

// Textbox.
Im_Widget_Textbox :: struct #no_copy {
	// "text_edit.State" stores a pointer.
	// We can't allow widgets to relocate in memory.
	box:                     text_edit.State,
	builder:                 strings.Builder,
	trailing_hit, is_inside: win.BOOL,
	text:                    Text_Layout_State,
	dragging:                bool,
	hot:                     f32,
}
im_widget_textbox_bind :: proc(node: ^Im_Node, w: ^Window, dt: f32) -> ^Im_Widget_Textbox {
	this, is_new := im_widget_replace(node, Im_Widget_Textbox)

	if is_new {
		this.builder = strings.builder_make(im_state.allocator)
		strings.write_string(&this.builder, "Default text")

		text_edit.init(&this.box, im_state.allocator, im_state.allocator)
		text_edit.setup_once(&this.box, &this.builder)
		this.box.clipboard_user_data = w
		this.box.set_clipboard = proc(user_data: rawptr, text: string) -> (ok: bool) {
			return wind_clipboard_set(auto_cast user_data, text)
		}
		this.box.get_clipboard = proc(user_data: rawptr) -> (text: string, ok: bool) {
			contents := wind_clipboard_get(auto_cast user_data, context.temp_allocator) or_return
			contents, _ = strings.remove_all(contents, "\n", context.temp_allocator)
			contents, _ = strings.remove_all(contents, "\r", context.temp_allocator)
			return contents, true
		}
		this.box.selection = {}
	}

	text_edit.update_time(&this.box)

	it: int
	for v in wind_events_next(&it, w) {
		#partial switch inner in v.value {
		case u32:
			(im_state.focus == node.id) or_continue
			defer wind_events_pop(&it)
			handle_key_input(&this.box, inner, v.modifiers)
		case rune:
			(im_state.focus == node.id) or_continue
			defer wind_events_pop(&it)
			handle_char_input(&this.box, inner)
		case In_Click:
			(inner.button == .Left) or_continue

			inside := im_in_box(node.measure, inner.pos)

			switch inner.type {
			case .Down, .Drag_Start, .Double:
				if inside {
					im_state.focus = node.id

					defer wind_events_pop(&it)

					layout := text_state_get_valid_layout(&this.text) or_continue

					metrics: d2w.DWRITE_HIT_TEST_METRICS
					hr := layout->HitTestPoint(
						f32(inner.pos.x - node.measure.pos.x),
						f32(inner.pos.y - node.measure.pos.y),
						&this.trailing_hit,
						&this.is_inside,
						&metrics,
					)
					win.SUCCEEDED(hr) or_continue

					if inner.type == .Drag_Start {
						this.dragging = true
					}

					if inner.type == .Double {
						blip_loc := metrics.textPosition
						this.box.selection = {int(blip_loc), int(blip_loc)}

						text_edit.perform_command(&this.box, .Word_Right)
						text_edit.perform_command(&this.box, .Select_Word_Left)
					} else {
						blip_loc := metrics.textPosition + (this.trailing_hit ? 1 : 0)
						this.box.selection = {int(blip_loc), int(blip_loc)}
					}
				} else {
					// TODO: This isn't compatible with other elements!!
					if im_state.focus == node.id {
						im_state.focus = 0
					}
					this.box.selection = {this.box.selection[0], this.box.selection[0]}
				}
			case .Drag_End:
				this.dragging = false
			case .Up:
			}
		case In_Move:
			(this.dragging) or_continue
			defer wind_events_pop(&it)

			layout := text_state_get_valid_layout(&this.text) or_continue

			metrics: d2w.DWRITE_HIT_TEST_METRICS
			hr := layout->HitTestPoint(f32(inner.pos.x - node.measure.pos.x), f32(inner.pos.y - node.measure.pos.y), &this.trailing_hit, &this.is_inside, &metrics)
			win.SUCCEEDED(hr) or_continue

			// TODO: Handle double-click word into drag (take min/max conditional).
			blip_loc := metrics.textPosition + (this.trailing_hit ? 1 : 0)
			this.box.selection[0] = int(blip_loc)
		}
	}

	str := strings.to_string(this.builder)
	text_state_hydrate(&this.text, Text_Desc{.Body, .THIN, .ITALIC, 96, str})
	text_state_cache(&this.text, {f32(node.measure.size.x), f32(node.measure.size.y)})

	if im_hot(node.measure, w.mouse, dt, &this.hot) {
		w.enable_drag = true
	}

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

	// render.target->PushAxisAlignedClip(&rect, .PER_PRIMITIVE)
	// defer render.target->PopAxisAlignedClip()

	hr: win.HRESULT
	{
		selection := this.box.selection
		selection_low, selection_high := text_edit.sorted_selection(&this.box)

		// Drag box.
		drag: if selection_low != selection_high {
			layout := text_state_get_valid_layout(&this.text) or_break drag

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
			win.SUCCEEDED(hr) or_break drag

			for test in hit_test[:hit_test_count] {
				gfx_attach_draw(render.attach, {test.left, test.top}, {test.width, test.height}, {1, 1, 1, 0.6})
			}
		}

		// Position blip.
		if im_state.focus == node.id {
			// Assume the top-left.
			offset: [2]f32
			height := f32(this.text.props.size)

			// But ideally, try to get position at the cursor.
			attempt: {
				layout := text_state_get_valid_layout(&this.text) or_break attempt

				// TODO: What does "isTrailingHit" even do here??
				metrics: d2w.DWRITE_HIT_TEST_METRICS
				hr = layout->HitTestTextPosition(u32(selection[0]), win.FALSE, &offset[0], &offset[1], &metrics)
				win.SUCCEEDED(hr) or_break attempt

				height = metrics.height
			}

			gfx_attach_draw(render.attach, {f32(node.measure.pos.x), f32(node.measure.pos.y)} + offset, {4, height}, {0, 1, 0, 1})
		}
	}

	str := strings.to_string(this.builder)
	layout, layout_ok := text_state_get_valid_layout(&this.text)
	text: if len(str) > 0 && layout_ok {
		layout->Draw(&Glyph_Draw_Meta{render, {1, 1, 1, im_state.focus == node.id ? 1 : 0.5}}, &glyph_renderer, f32(node.measure.pos.x), f32(node.measure.pos.y))
	}
}

// Button.
Im_Widget_Button :: struct {
	click: bool,
	hot:   f32,
}
im_widget_button_bind :: proc(node: ^Im_Node, w: ^Window, dt: f32) -> ^Im_Widget_Button {
	this, _ := im_widget_replace(node, Im_Widget_Button)

	im_hot(node.measure, w.mouse, dt, &this.hot)
	node.color *= (1 + 0.4 * this.hot)

	return this
}
im_widget_button_destroy :: proc(this: ^Im_Widget_Button) {
}
im_widget_button_draw :: proc(render: Render, node: ^Im_Node, this: ^Im_Widget_Button) {
	gfx_attach_draw(render.attach, {f32(node.measure.pos.x), f32(node.measure.pos.y)}, {f32(node.measure.size.x), f32(node.measure.size.y)}, node.color)
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
	text: {
		layout := text_state_get_valid_layout(&this.text) or_break text
		layout->Draw(&Glyph_Draw_Meta{render, node.color}, &glyph_renderer, f32(node.measure.pos.x), f32(node.measure.pos.y))
	}
}
im_widget_text_destroy :: proc(node: ^Im_Node, this: ^Im_Widget_Text) {
	node.style.measure_func = nil
	text_state_destroy(&this.text)
}

// Default (no widget).
im_widget_none_draw :: proc(render: Render, node: ^Im_Node) {
	// render.brush->SetColor(auto_cast &node.color)
	// if node.color == p[.Background] {
	// 	render.target->FillRectangle(&rect, render.brush)
	// 	render.target->FillRectangle(&rect, render.bmp)
	// } else {
	// 	render.target->FillRectangle(&rect, render.brush)
	// }
	gfx_attach_draw(render.attach, {f32(node.measure.pos.x), f32(node.measure.pos.y)}, {f32(node.measure.size.x), f32(node.measure.size.y)}, node.color)
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

// TODO: We require the node here so widgets can unbind callbacks on their owned nodes; not ideal?
im_widget_dyn_destroy :: proc(node: ^Im_Node, p: Im_Wrapper) {
	switch v in p {
	case ^Im_Widget_Textbox:
		im_widget_textbox_destroy(v)
	case ^Im_Widget_Button:
		im_widget_button_destroy(v)
	case ^Im_Widget_Text:
		im_widget_text_destroy(node, v)
	}
}

im_widget_dyn_draw :: proc(render: Render, node: ^Im_Node, p: Im_Wrapper) {
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
			im_widget_dyn_destroy(node, existing)
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
