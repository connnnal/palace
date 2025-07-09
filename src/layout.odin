package main

import "base:intrinsics"
import "base:runtime"
import "core:log"
import "core:reflect"

Ly_Axis_Flex :: enum {
	Row,
	Col,
	RowReverse,
	ColReverse,
}

Ly_Axis_World :: enum {
	X,
	Y,
}

Ly_Dim :: union {
	// Nil, indefinite
	i32, // Pixels, definite
	f32, // Float, definite
}

// TODO: What does the spec call this datatype?
Ly_Justify :: enum {
	FlexStart,
	FlexEnd,
	Center,
	SpaceBetween,
	SpaceAround,
}

// TODO: What does the spec call this datatype?
Ly_Align :: enum {
	Stretch,
	FlexStart,
	FlexEnd,
	Center,
	Baseline,
}

Ly_Measure_Func :: #type proc(node: ^Ly_Node, available: [2]Ly_Length) -> [2]Ly_Length

// Ly_Size :: union #no_nil {
// 	[2]Ly_Dim,
// 	Ly_Measure_Func,
// }

Ly_Constants :: struct {
	size:            [2]Ly_Dim,
	measure_func:    Ly_Measure_Func,
	margin:          [4]i32,
	padding:         [4]i32,
	justify_content: Ly_Justify,
	align_items:     Ly_Align,
	gap:             i32,
	flow:            Ly_Axis_Flex,
}

Ly_Output :: struct {
	pos:   [2]i32,
	size:  [2]i32,
	basis: i32, // Flex basis
}

Ly_Node :: struct {
	using connections: struct {
		parent, first, last, next, prev: ^Ly_Node,
	},
	style:             Ly_Constants,
	measure:           Ly_Output,
}

// Sever connections etc. Allows object re-use, call per-frame in an imgui.
ly_node_clear :: #force_inline proc(node: ^Ly_Node) {
	node.connections = {}
}

ly_node_insert :: #force_inline proc(parent, child: ^Ly_Node) {
	if parent.last == nil {
		parent.last = child
		parent.first = child
	} else {
		child.prev = parent.last
		parent.last.next = child
		parent.last = child
	}
}

// "nil" means indefinite.
Ly_Length :: Maybe(i32)

ly_evaluate_length :: proc(dim: Ly_Dim, available: Ly_Length) -> (length: Ly_Length) {
	available, available_definite := available.?

	if available_definite {
		switch value in dim {
		case i32:
			return value
		case f32:
			return i32(f32(available) * value)
		case nil:
			return nil
		}
	} else {
		switch value in dim {
		case i32:
			return value
		case f32, nil:
			return nil
		}
	}
	unreachable()
}

ly_available_inner :: proc(style: Ly_Constants, available: [2]Ly_Length) -> (out: [2]Ly_Length) #no_bounds_check {
	if value, ok := ly_evaluate_length(style.size[0], available[0]).?; ok {
		out[0] = value
	} else {
		if value, ok := available[0].?; ok {
			// 9.2.2:
			// "otherwise, subtract the flex container’s margin, border, and padding from the space	
			// available to the flex container in that dimension and use that value".
			out[0] = value - (style.margin[0] + style.padding[0]) * 2
		}
	}
	if value, ok := ly_evaluate_length(style.size[1], available[1]).?; ok {
		out[1] = value
	} else {
		if value, ok := available[1].?; ok {
			// 9.2.2:
			// "otherwise, subtract the flex container’s margin, border, and padding from the space	
			// available to the flex container in that dimension and use that value".
			out[1] = value - (style.margin[1] + style.padding[1]) * 2
		}
	}
	return
}

ly_outer :: proc(style: Ly_Constants, available: [2]Ly_Length, content: [2]i32) -> (out: [2]i32) #no_bounds_check {
	if value, ok := ly_evaluate_length(style.size[0], available[0]).?; ok {
		out[0] = value
	} else {
		out[0] = content[0] + style.padding[0] * 2
	}
	if value, ok := ly_evaluate_length(style.size[1], available[1]).?; ok {
		out[1] = value
	} else {
		out[1] = content[1] + style.padding[1] * 2
	}
	return
}

ly_position_flexbox :: proc(node: ^Ly_Node, available: [2]Ly_Length) {
	available_inner := ly_available_inner(node.style, available)

	mx := node.style.flow
	cx: Ly_Axis_Flex = node.style.flow == .Row ? .Col : .Row

	flex_line: i32
	for child := node.first; child != nil; child = child.next {
		defer flex_line += child.measure.size[int(mx)]
		defer flex_line += node.style.gap

		child.measure.pos[0] = node.measure.pos[0] + node.style.padding[0]
		child.measure.pos[1] = node.measure.pos[1] + node.style.padding[1]

		child.measure.pos[int(mx)] += flex_line
	}

	if cross_size, ok := available_inner[int(cx)].?; ok {
		for child := node.first; child != nil; child = child.next {
			if child.style.size[int(cx)] == nil {
				child.measure.size[int(cx)] = cross_size
			}
		}
	}

	for child := node.first; child != nil; child = child.next {
		ly_position_flexbox(child, available_inner)
	}
}

// TODO: Imagine if we made this SIMD lol.
ly_compute_flexbox_layout :: proc(node: ^Ly_Node, available: [2]Ly_Length) -> [2]i32 {
	if node.style.measure_func != nil {
		available := node.style.measure_func(node, available)
		node.measure.size = {available.x.? or_else 0, available.y.? or_else 0}
		return node.measure.size
	}

	available_inner := ly_available_inner(node.style, available)

	mx := node.style.flow
	cx: Ly_Axis_Flex = node.style.flow == .Row ? .Col : .Row

	content: [2]i32
	{
		child_count: i32 = 0
		for child := node.first; child != nil; child = child.next {
			defer child_count += 1

			ly_compute_flexbox_layout(child, available_inner)
			content[int(mx)] += child.measure.size[int(mx)]
			content[int(cx)] = max(content[cx], child.measure.size[int(cx)])
		}

		content[i32(mx)] += node.style.gap * max(0, child_count - 1)
	}

	node.measure.size = ly_outer(node.style, available, content)

	ly_position_flexbox(node, available)

	return node.measure.size
}
