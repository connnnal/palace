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

Ly_Dim :: struct {
	scale:  f32,
	offset: i32,
}
LY_AUTO :: Ly_Dim{0, 0}

// TODO: Use this!
// Ly_Dim :: bit_field u32 {
// 	scale:  i8  | 8,
// 	offset: i32 | 24,
// }
// LY_AUTO :: Ly_Dim{}

Ly_Constants :: struct {
	size:    [2]Ly_Dim,
	padding: [2]i32,
	gap:     i32,
	flow:    Ly_Axis_Flex,
	text:    string,
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

// Ly_State :: struct {
// 	allocator: runtime.Allocator,
// }

// ly_state_init :: proc(state: ^Ly_State, allocator := context.allocator) {

// }

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

ly_measure_on :: proc(node: ^Ly_Node, available: [2]i32, axis: Ly_Axis_World) -> i32 {
	size := ly_compute_flexbox_layout(node, available)
	return size[int(axis)]
}

ly_compute_flexbox_layout :: proc(node: ^Ly_Node, available: [2]i32) -> [2]i32 {
	available: [2]i32 = {
		i32(f32(available[0]) * node.style.size[0].scale) + node.style.size[0].offset,
		i32(f32(available[1]) * node.style.size[1].scale) + node.style.size[1].offset,
	}
	padding := node.style.padding

	{
		mx := node.style.flow

		content: i32 = 0
		child_count: i32 = 0
		for child := node.first; child != nil; child = child.next {
			child.measure.pos = node.measure.pos
			child.measure.pos[int(mx)] += content + child_count * node.style.gap
			child.measure.pos += padding

			child_count += 1
			child.measure.basis = ly_measure_on(child, available - padding * 2, Ly_Axis_World(mx))
			content += child.measure.basis
		}

		gaps := node.style.gap * max(0, child_count - 1)
		content += gaps

		if node.style.size[int(mx)] == LY_AUTO {
			available[int(mx)] = content + padding[int(mx)] * 2
		}
	}
	{
		cx: Ly_Axis_Flex = node.style.flow == .Row ? .Col : .Row

		content: i32 = 0

		for child := node.first; child != nil; child = child.next {
			cross := ly_measure_on(child, available - padding * 2, Ly_Axis_World(cx))
			content = max(content, cross)
		}

		if node.style.size[int(cx)] == LY_AUTO {
			available[int(cx)] = content + padding[int(cx)] * 2
		}
	}

	node.measure.size = available

	// log.info(node.style.size, available)

	return available
}
