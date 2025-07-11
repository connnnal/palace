package main

import "base:runtime"
import "core:log"
import text_edit "core:text/edit"

Im_Widget_Textbox :: struct {
	destroy: proc(w: ^Im_Widget_Textbox),
	box:     text_edit.State,
}

Im_Widget_Button :: struct {
	destroy: proc(w: ^Im_Widget_Button),
	box:     text_edit.State,
}

WIDGET_SIZE :: max(size_of(Im_Widget_Textbox), size_of(Im_Widget_Button))

// We don't know the inner type of our widget, use worst-case alignment.
// Could fallback to "runtime.DEFAULT_ALIGNMENT".
WIDGET_ALIGN :: max(align_of(Im_Widget_Textbox), align_of(Im_Widget_Button))
#assert(WIDGET_ALIGN < runtime.DEFAULT_ALIGNMENT, "widget alignment fell back to worst case")

Im_Wrapper :: struct {
	// TODO: Do we need a maybe? Likely typeid '0' is reserved for nil?
	using _: struct #raw_union #align (WIDGET_ALIGN) {
		destroy: proc(widget: rawptr),
		buf:     [WIDGET_SIZE]u8,
	},
	inner:   typeid,
}

// @(private = "file")
// im_widget_type :: proc(combo: ^Im_Widget) -> Maybe(typeid) {
// 	switch _ in combo {
// 	case Im_Widget_Textbox:
// 		return typeid_of(Im_Widget_Textbox)
// 	}
// 	return nil
// }

im_widget_textbox_create :: proc(state: ^Im_State, widget: ^Im_Widget_Textbox) {
	widget.destroy = im_widget_destroy
	return
}

im_widget_textbox_destroy :: proc(w: ^Im_Widget_Textbox) {
	return
}

im_widget_button_create :: proc(state: ^Im_State, widget: ^Im_Widget_Button) {
	widget.destroy = im_widget_destroy
	return
}

im_widget_button_destroy :: proc(w: ^Im_Widget_Button) {
	return
}

im_widget_create :: proc {
	im_widget_textbox_create,
	im_widget_button_create,
}
im_widget_destroy :: proc {
	im_widget_textbox_destroy,
	im_widget_button_destroy,
}

// im_widget_create :: proc(state: ^Im_State, $T: typeid) -> T {
// 	when T == Im_Widget_Textbox {
// 		out: Im_Widget_Textbox

// 		text_edit.init(&out.box, state.allocator, state.allocator)

// 		return out
// 	}
// }

// im_widget_destroy :: proc(state: ^Im_State, widget: ^$T) {
// 	when T == Im_Widget_Textbox {

// 	} else when 1 == 2 {
// 		#assert("fail!")
// 	}
// }

// im_widget_hydrate :: proc(state: ^Im_State, node: ^Im_Node, $T: typeid) -> ^T {
// 	existing := im_widget_type(&node.widget)

// 	if existing != nil && existing != typeid_of(T) {
// 		// Unions are data followed by tag; we can just cast a pointer.
// 		im_widget_destroy(state, cast(^T)&node.widget)
// 	}

// 	if existing != typeid_of(T) {
// 		node.widget = im_widget_create(state)
// 	}

// 	return nil
// }

im_widget_hydrate :: proc(state: ^Im_State, node: ^Im_Node, $T: typeid) -> ^T where size_of(T) <= WIDGET_SIZE {
	#assert(size_of(T) <= WIDGET_SIZE, "provided widget type is oversized")

	existing := node.wrapper.inner
	has_existing := existing != nil

	if has_existing && existing != typeid_of(T) {
		node.wrapper.destroy(state)
	}

	if !has_existing || existing != typeid_of(T) {
		node.wrapper.inner = typeid_of(T)
		value: T
		im_widget_create(state, &value)
		(cast(^T)raw_data(&node.wrapper.buf))^ = value
	}

	return cast(^T)raw_data(&node.wrapper.buf)
}
