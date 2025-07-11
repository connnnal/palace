package main

import "base:intrinsics"
import "base:runtime"
import "core:log"
import "core:strings"
import text_edit "core:text/edit"

import win "core:sys/windows"
import d2w "lib:odin_d2d_dwrite"

Im_Widget_Textbox :: struct {
	destroy: proc(w: ^Im_Widget_Textbox),
	draw:    proc(state: ^Im_State, node: ^Im_Node, w: ^Im_Widget_Textbox, r: Render),
	box:     text_edit.State,
	builder: strings.Builder,
}

Im_Widget_Button :: struct {
	destroy: proc(w: ^Im_Widget_Button),
	draw:    proc(state: ^Im_State, node: ^Im_Node, w: ^Im_Widget_Button, r: Render),
	click:   bool,
}

// WIDGET_SIZE :: max(size_of(Im_Widget_Textbox), size_of(Im_Widget_Button))
WIDGET_SIZE :: 272

// We don't know the inner type of our widget, use worst-case alignment.
// Could fallback to "runtime.DEFAULT_ALIGNMENT".
WIDGET_ALIGN :: max(align_of(Im_Widget_Textbox), align_of(Im_Widget_Button))
#assert(WIDGET_ALIGN < runtime.DEFAULT_ALIGNMENT, "widget alignment fell back to worst case")

Im_Wrapper :: struct {
	using _: struct #raw_union #align (WIDGET_ALIGN) {
		using _: struct {
			destroy: proc(w: rawptr),
			draw:    proc(state: ^Im_State, node: ^Im_Node, w: rawptr, r: Render),
		},
		buf:     [WIDGET_SIZE]u8,
	},
	// TODO: Do we need a maybe? Likely typeid '0' is reserved for nil?
	inner:   typeid,
}

// Textbox

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
	// focus = false
	// fx.set_char_callback(nil)
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

im_widget_textbox_create :: proc(state: ^Im_State, w: ^Im_Widget_Textbox) {
	w.destroy = im_widget_destroy
	w.draw = im_widget_textbox_draw

	w.builder = strings.builder_make(state.allocator)

	// TODO: We can't use "text_edit.setup_once" because it uses a pointer, and widgets can move in memory.
	text_edit.init(&w.box, state.allocator, state.allocator)
	// text_edit.setup_once(&w.box, &w.builder)
}
im_widget_textbox_destroy :: proc(w: ^Im_Widget_Textbox) {
	text_edit.destroy(&w.box)
	strings.builder_destroy(&w.builder)
}
im_widget_textbox_update :: proc(state: ^Im_State, node: ^Im_Node, w: ^Im_Widget_Textbox) {
	text_edit.update_time(&w.box)
	w.box.builder = &w.builder

	it: int
	for v in wind_events_next(&it, nil) {
		inner := v.value.(rune) or_continue
		defer wind_events_pop(&it)

		handle_char_input(&w.box, inner)
	}

	str := strings.to_string(w.builder)
	if len(str) > 0 {
		text_state_hydrate(&node.text, Text_Desc{.Body, .THIN, .ITALIC, 128, str})
	}
}
im_widget_textbox_draw :: proc(state: ^Im_State, node: ^Im_Node, w: ^Im_Widget_Textbox, render: Render) {
	select: {
		layout := text_state_get_valid_layout(&node.text) or_break select

		selection := w.box.selection

		hit_test: [8]d2w.DWRITE_HIT_TEST_METRICS
		hit_test_count: u32
		hr := layout->HitTestTextRange(
			u32(selection.y),
			u32(selection.x),
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
	}
}

// Button

im_widget_button_create :: proc(state: ^Im_State, w: ^Im_Widget_Button) {
	w.destroy = im_widget_destroy
}
im_widget_button_destroy :: proc(w: ^Im_Widget_Button) {
}
im_widget_button_update :: proc(state: ^Im_State, node: ^Im_Node, w: ^Im_Widget_Button) {
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

im_widget_hydrate :: proc(state: ^Im_State, node: ^Im_Node, $T: typeid) -> (out: ^T) where size_of(T) <= WIDGET_SIZE,
	align_of(T) <= WIDGET_ALIGN,
	intrinsics.type_has_field(T, "destroy"),
	intrinsics.type_is_proc(intrinsics.type_field_type(T, "destroy")),
	intrinsics.type_proc_parameter_count(intrinsics.type_field_type(T, "destroy")) == 1,
	intrinsics.type_proc_parameter_type(intrinsics.type_field_type(T, "destroy"), 0) == ^T,
	intrinsics.type_proc_return_count(intrinsics.type_field_type(T, "destroy")) == 0 {

	existing := node.wrapper.inner
	has_existing := existing != nil
	out = cast(^T)raw_data(&node.wrapper.buf)

	if has_existing && existing != typeid_of(T) {
		node.wrapper.destroy(raw_data(&node.wrapper.buf))
	}

	if !has_existing || existing != typeid_of(T) {
		node.wrapper.inner = typeid_of(T)
		value: T
		im_widget_create(state, &value)
		out^ = value
	}

	im_widget_update(state, node, out)

	return
}

im_widget_draw :: proc(state: ^Im_State, node: ^Im_Node, r: Render) {
	if node.wrapper.inner != nil && node.wrapper.draw != nil {
		node.wrapper.draw(state, node, raw_data(&node.wrapper.buf), r)
	}
}
