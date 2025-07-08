package main

import "base:runtime"
import "core:log"

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
Ly_Align :: enum {
	FlexStart,
	FlexEnd,
	Center,
	SpaceBetween,
	SpaceAround,
	Stretch,
}

// TODO: What does the spec call this datatype?
Ly_Edge :: enum {
	Auto,
	FlexStart,
	FlexEnd,
	Center,
	Baseline,
	Stretch,
}

// Ly_Padding :: struct #raw_union {
// 	px:    struct {
// 		left, right, top, bottom: i32,
// 	},
// 	world: [Ly_Axis_World][2]i32,
// 	array: [4]i32,
// }

Ly_Constants :: struct {
	size:          [2]Ly_Dim,
	margin:        [4]i32,
	padding:       [4]i32,
	align_content: Ly_Align,
	align_items:   Ly_Edge,
	gap:           i32,
	flow:          Ly_Axis_Flex,
	text:          string,
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

ly_measure_on :: proc(node: ^Ly_Node, available: [2]Ly_Length, axis: Ly_Axis_World) -> i32 {
	size := ly_compute_flexbox_layout(node, available)
	return size[int(axis)].? or_else 0
}

ly_evaluate_length :: proc(elem_dim: Ly_Dim, elem_padding: i32, available: Ly_Length) -> (length: Ly_Length) {
	available, available_definite := available.?

	if available_definite {
		switch value in elem_dim {
		case i32:
			return value
		case f32:
			return i32(f32(available) * value)
		case nil:
			// 9.2.2:
			// "otherwise, subtract the flex container’s margin, border, and padding from the space	
			// available to the flex container in that dimension and use that value".
			return max(0, available - elem_padding * 2)
		}
	} else {
		switch value in elem_dim {
		case i32:
			return value
		case f32, nil:
			return nil
		}
	}
	unreachable()
}

ly_determine_available_space :: proc(style: Ly_Constants, available: [2]Ly_Length) -> (out: [2]Ly_Length) #no_bounds_check {
	if value, ok := ly_evaluate_length(style.size[0], style.padding[0], available[0]).?; ok {
		out[0] = value
	} else {
		if value, ok := available[0].?; ok {
			out[0] = value - style.margin[0] * 2
		}
	}
	if value, ok := ly_evaluate_length(style.size[1], style.padding[1], available[1]).?; ok {
		out[1] = value
	} else {
		if value, ok := available[1].?; ok {
			out[1] = value - style.margin[1] * 2
		}
	}
	return
}

// TODO: Imagine if we made this SIMD lol.
ly_compute_flexbox_layout :: proc(node: ^Ly_Node, available: [2]Ly_Length) -> [2]Ly_Length {
	available := ly_determine_available_space(node.style, available)
	padding := node.style.padding

	{
		mx := node.style.flow

		content: i32 = 0
		child_count: i32 = 0
		for child := node.first; child != nil; child = child.next {
			defer child_count += 1

			child.measure.pos = node.measure.pos
			child.measure.pos[int(mx)] += content + child_count * node.style.gap
			child.measure.pos += padding[int(mx) * 2]

			ly_measure_on(child, available, Ly_Axis_World(mx))
			content += child.measure.size[int(mx)]
		}

		gaps := node.style.gap * max(0, child_count - 1)
		content += gaps

		if available[int(mx)] == nil {
			available[int(mx)] = content + padding[int(mx)] * 2
		}
	}
	{
		cx: Ly_Axis_Flex = node.style.flow == .Row ? .Col : .Row

		content: i32 = 0
		for child := node.first; child != nil; child = child.next {
			cross := child.measure.size[int(cx)]
			content = max(content, cross)
		}

		if available[int(cx)] == nil {
			available[int(cx)] = content + padding[int(cx)] * 2
		}
	}

	node.measure.size.x = available.x.? or_else 0
	node.measure.size.y = available.y.? or_else 0

	return available
}
