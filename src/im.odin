package main

import "base:runtime"
import sa "core:container/small_array"
import "core:fmt"
import "core:hash"
import "core:log"
import "core:math"
import "core:strings"

import d2w "lib:odin_d2d_dwrite"
import va "lib:virtual_array"

Id :: u32

@(private)
id_extend :: proc(base: Id, off: Id) -> Id {
	id := base

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

Im_State :: struct #no_copy {
	allocator: runtime.Allocator,
	stack:     sa.Small_Array(8, ^Im_Node),
	cache:     map[Id]^Im_Node,
	frame:     Frame,
	draws:     [dynamic]^Im_Node,
	nodes:     va.Virtual_Array(Im_Node),
	widgets:   va.Virtual_Array(Im_Wrapper_Anon),
}

im_state_init :: proc(state: ^Im_State, allocator := context.allocator) {
	state.allocator = allocator
	state.draws.allocator = allocator
	state.cache.allocator = allocator
	state.frame = 2
}

im_state_destroy :: proc(state: ^Im_State) {
	delete(state.cache)
	delete(state.draws)
	va.destroy(&state.nodes)
	va.destroy(&state.widgets)
}

Im_Decor :: struct {
	color: [4]f32,
}

// Ly_Node as the first parameter to allow downcasting.
Im_Node :: struct {
	using ly:    Ly_Node,
	id:          Id,
	frame:       Frame,
	using decor: Im_Decor,
	text:        Maybe(Text_Layout_State),
	hot:         f32,
	wrapper:     Im_Wrapper,
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

// Convenience wrapper over user-defined node properties.
Im_Props :: struct {
	using constants: Ly_Constants,
	using decor:     Im_Decor,
	text:            Maybe(Text_Desc),
}

@(deferred_out = im_scope_end)
im_scope :: proc(id: Id, props: Im_Props) -> ^Im_Node {
	context.allocator = im_state.allocator

	parent, has_parent := sa.get_safe(im_state.stack, im_state.stack.len - 1)
	id := id_extend(id, has_parent ? parent.id : 0)

	_, value_ptr, just_inserted := map_entry(&im_state.cache, id) or_else log.panic("failed to allocate map space")
	if just_inserted {
		value_ptr^, _ = va.alloc(&im_state.nodes)
	}

	node := value_ptr^
	switch node.frame {
	case im_state.frame:
		// Node used this frame!
		log.panicf("hash collision %v", id)
	case im_state.frame - 1:
		// Node used previous frame. Continuity.
		break
	case:
		// Node is stale, break continuity.
		text_state_destroy(&node.text)
		node^ = {}
	}

	ly_node_clear(node)

	node.decor = props.decor
	node.style = props.constants
	text_state_hydrate(&node.text, props.text)

	node.id = id
	node.frame = im_state.frame
	node.style = props
	node.frame = im_state.frame
	if has_parent {
		ly_node_insert(parent, node)
	}

	if _, ok := props.text.?; ok {
		text_measure :: proc(node: ^Ly_Node, available: [2]Ly_Length) -> [2]i32 {
			node := cast(^Im_Node)node

			available := [2]f32{available.x != nil ? f32(available.x.(i32)) : max(f32), available.y != nil ? f32(available.y.(i32)) : max(f32)}
			layout := text_state_cache(&node.text, available)

			// Fear not! DWrite metrics are lazily evaluated.
			// Updating props can trigger a slow or fast path, depending on their type.
			// I.e. max dimensions is free; text break sizes from the previous layout control invalidation.
			metrics: d2w.DWRITE_TEXT_METRICS
			hr := layout->GetMetrics(&metrics)
			check(hr, "failed to get text metrics")

			return {i32(metrics.width), i32(metrics.height)}
		}
		node.style.measure_func = text_measure
	}

	log.ensure(sa.append(&im_state.stack, node), "node stack overflow")

	return node
}

im_scope_end :: proc(node: ^Im_Node) {
	popped := sa.pop_back_safe(&im_state.stack) or_else log.panic("stack exhausted")
	log.assert(popped == node, "stack mismatch")
}

im_leaf :: proc(id: Id, style: Im_Props) -> ^Im_Node {
	return im_scope(id, style)
}

im_recurse :: proc(root: ^Im_Node, available: [2]i32) {
	ly_compute_flexbox_layout(root, {available.x, available.y})
}

// TODO: Ideally this is template-ised on the "mouse_ok" param.
im_hot :: proc(state: ^Im_State, mouse: Maybe([2]i32), dt: f32) {
	mouse, mouse_ok := mouse.?

	for _, &node in state.cache {
		in_bounds: bool

		#no_bounds_check if mouse_ok {
			measure := node.ly.measure

			into := mouse - measure.pos
			size := measure.size
			in_bounds = into.x >= 0 && into.x < size.x && into.y >= 0 && into.y < size.y
		}

		node.hot = exp_decay(node.hot, in_bounds ? 1 : 0, 28, dt)
	}
}

im_dump :: proc(node: ^Im_Node, allocator := context.temp_allocator) -> string {
	b: strings.Builder
	strings.builder_init(&b, allocator)

	stack: [dynamic]^Im_Node
	stack.allocator = context.temp_allocator
	append(&stack, node)

	depth := 1
	for node in pop_safe(&stack) {
		if node == nil {
			depth -= 1
			continue
		}
		// Visit.
		{
			for v in 0 ..< depth {fmt.sbprint(&b, "\t")}
			fmt.sbprintf(&b, "%#x\n", node.id)
			for v in 0 ..< depth {fmt.sbprint(&b, "\t")}
			fmt.sbprintf(&b, "size: %v\n", node.measure.size)
			for v in 0 ..< depth {fmt.sbprint(&b, "\t")}
			fmt.sbprintf(&b, "pos: %v\n", node.measure.pos)
		}
		// Children.
		append(&stack, cast(^Im_Node)node.next)
		if first := node.first; first != nil {
			depth += 1
			append(&stack, cast(^Im_Node)first)
		}
	}

	return strings.to_string(b)
}

im_state_draws :: proc(state: ^Im_State, node: ^Im_Node) {
	append(&state.draws, node)

	for node := node.last; node != nil; node = node.prev {
		im_state_draws(state, cast(^Im_Node)node)
	}
}

// "a = expDecay(a, b, decay, deltaTime)"
// Where dt is in seconds, decay is ~1..<25.
// https://youtu.be/LSNQuFEDOyQ?t=3000.
exp_decay :: proc "contextless" (a, b, decay, dt: f32) -> f32 {
	// TODO: Replace "exp" with an approximation.
	// http://spfrnd.de/posts/2018-03-10-fast-exponential.html.
	// https://scicomp.stackexchange.com/a/37322.
	return b + (a - b) * math.exp(-decay * dt)
}
