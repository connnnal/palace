package main

import "base:runtime"
import sa "core:container/small_array"
import "core:hash"
import "core:log"

Palette :: enum {
	Background,
	Foreground,
	Text,
}

Id :: u32

@(private)
id_extend :: proc(base: Id, off: Id) -> Id {
	id: Id = base

	id += u32(off)
	id += (id << 10)
	id ~= (id >> 6)

	id += (id << 3)
	id ~= (id >> 11)
	id += (id << 15)

	return max(1, id)
}

id_name :: proc($name: string) -> Id {
	return max(1, #hash(name, "fnv32a"))
}

id_name_offset :: proc($name: string, off: int) -> Id {
	return id_extend(id_name(name), Id(off))
}

id_str :: proc(name: string) -> Id {
	name := transmute([]u8)name
	return max(1, hash.fnv32a(name))
}

id :: proc {
	id_name,
	id_name_offset,
	id_str,
}

Frame :: u64

Im_State :: struct {
	allocator: runtime.Allocator,
	stack:     sa.Small_Array(8, ^Im_Node),
	cache:     map[Id]^Im_Node,
	frame:     Frame,
}

im_state_init :: proc(state: ^Im_State) {
	state.allocator = context.allocator
	state.frame = 2
}

Im_Dim :: struct {
	scale:  f32,
	offset: i32,
}

Im_Layout :: struct {
	flow:    bool,
	padding: [4]i32,
	gap:     i32,
}

Im_Style :: struct {
	size:     #soa[2]Im_Dim,
	layout:   Im_Layout,
	bg_color: Palette,
	fg_color: Palette,
	text:     string,
}

Im_Node :: struct {
	id:                              Id,
	frame:                           Frame,
	measure:                         Im_Measure,
	parent, first, last, next, prev: ^Im_Node,
	style:                           Im_Style,
}

Im_Measure :: struct {
	off:  [2]i32,
	size: [2]i32,
}

// TODO: Faster to set global, then memcpy back? Not ptr?
@(thread_local)
im_state: ^Im_State

im_frame_begin :: proc(state: ^Im_State) {
	assert(im_state == nil)
	state.frame += 1
	im_state = state
}

im_frame_end :: proc(state: ^Im_State) {
	im_state = nil
}

@(deferred_out = im_push_end)
im_push :: proc(id: Id, style: Im_Style) -> ^Im_Node {
	context.allocator = im_state.allocator

	parent, has_parent := sa.get_safe(im_state.stack, im_state.stack.len - 1)
	id := id_extend(id, has_parent ? parent.id : 0)

	key_ptr, value_ptr, just_inserted := map_entry(&im_state.cache, id) or_else panic("failed to allocate map space")

	if just_inserted {
		// TODO: Which allocator?
		value_ptr^ = new(Im_Node, context.allocator)
	} else {
		assert(value_ptr^.frame < im_state.frame, "hash collision")
	}

	this := value_ptr^
	this.parent = parent
	this.style = style
	this.frame = im_state.frame
	if has_parent {
		if parent.last == nil {
			parent.first = this
			parent.last = this
		} else {
			this.prev = parent.last
			parent.last = this
		}
	}
	{
		this.measure.size = {style.size[0].offset, style.size[1].offset}
	}

	ensure(sa.append(&im_state.stack, this), "node stack overflow")

	return this
}

im_push_end :: proc(node: ^Im_Node) {
	sa.pop_back(&im_state.stack)

	for child := node.first; child != nil; child = child.next {

	}
}
