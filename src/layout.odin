package main

import "base:intrinsics"
import "base:runtime"
import "core:log"

Ly_Flow :: enum {
	Row,
	Col,
	RowReverse,
	ColReverse,
}

Ly_Axis :: enum {
	Main,
	Cross,
}

ly_axes :: proc(flow: Ly_Flow) -> (world_x, world_y: Ly_Axis) {
	switch flow {
	case .Row, .RowReverse:
		return .Main, .Cross
	case .Col, .ColReverse:
		return .Cross, .Main
	}
	unreachable()
}

Ly_Dim :: union {
	// Nil, indefinite
	i32, // Pixels, definite
	f32, // Float, definite
}

// TODO: What does the spec call this datatype?
// TODO: "SpaceBetween" and "SpaceAround" omitted, not applicable without flex lines.
Ly_Justify :: enum {
	FlexStart,
	FlexEnd,
	Center,
}

// TODO: What does the spec call this datatype?
// TODO: "Baseline" omitted, needs a lot of surrounding work.
Ly_Align :: enum {
	Stretch,
	FlexStart,
	FlexEnd,
	Center,
}

// We could handle unknown lengths from our custom measure function,
// but Yoga treats this as an error, so we probably should too.
// It simplifies our logic a little bit.
Ly_Measure_Func :: #type proc(node: ^Ly_Node, available: [2]Ly_Length) -> [2]i32

#assert(size_of(Ly_Dim) == 8)
#assert(size_of(Ly_Constants) == 64)

Ly_Constants :: struct {
	size:         [2]Ly_Dim,
	measure_func: Ly_Measure_Func,
	using _:      struct #raw_union {
		// Left, right, top, bottom.
		margin:      [2][2]i32,
		margin_flat: [4]i32,
	},
	using _:      struct #raw_union {
		// Left, right, top, bottom.
		padding:      [2][2]i32,
		padding_flat: [4]i32,
	},
	using _:      bit_field u32 {
		justify_content: Ly_Justify | 4,
		align_items:     Ly_Align   | 4,
		gap:             i32        | 8,
		flow:            Ly_Flow    | 4,
		grow:            bool       | 1,
		absolute:        bool       | 1,
	},
}

Ly_Output :: struct {
	pos, size: [2]i32,
	content:   [Ly_Axis]i32,
}

Ly_Node :: struct #min_field_align(64) {
	using connections: struct {
		first, last, next, prev: ^Ly_Node,
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

Ly_Length :: distinct i32
LY_UNDEFINED :: max(Ly_Length)

ly_length :: #force_inline proc(l: Ly_Length) -> (i32, bool) {
	return i32(l), l != LY_UNDEFINED
}

ly_evaluate_length :: proc(dim: Ly_Dim, available: Ly_Length) -> (length: Ly_Length) {
	available, available_definite := ly_length(available)

	if available_definite {
		switch value in dim {
		case i32:
			return Ly_Length(value)
		case f32:
			return Ly_Length(f32(available) * value)
		case nil:
			return LY_UNDEFINED
		}
	} else {
		switch value in dim {
		case i32:
			return Ly_Length(value)
		case f32, nil:
			return LY_UNDEFINED
		}
	}
	unreachable()
}

ly_available_inner :: proc(style: Ly_Constants, available: [2]Ly_Length) -> (out: [2]Ly_Length) #no_bounds_check {
	inset: [2]i32 = {style.padding[0][0] + style.padding[0][1], style.padding[1][0] + style.padding[1][1]}

	if value, ok := ly_length(ly_evaluate_length(style.size[0], available[0])); ok {
		out[0] = Ly_Length(value - inset[0])
	} else {
		// 9.2.2:
		// "otherwise, subtract the flex container’s margin, border, and padding from the space	
		// available to the flex container in that dimension and use that value".
		if value, ok := ly_length(available[0]); ok {
			out[0] = Ly_Length(value - inset[0])
		}
	}
	if value, ok := ly_length(ly_evaluate_length(style.size[1], available[1])); ok {
		out[1] = Ly_Length(value - inset[1])
	} else {
		// 9.2.2:
		// "otherwise, subtract the flex container’s margin, border, and padding from the space	
		// available to the flex container in that dimension and use that value".
		if value, ok := ly_length(available[1]); ok {
			out[1] = Ly_Length(value - inset[1])
		}
	}

	return
}

ly_outer :: proc(style: Ly_Constants, box: [2]i32) -> (out: [2]i32) #no_bounds_check {
	return box + {style.margin[0][0] + style.margin[0][1], style.margin[1][0] + style.margin[1][1]}
}

ly_inner :: proc(style: Ly_Constants, box: [2]i32) -> (out: [2]i32) #no_bounds_check {
	return box - {style.padding[0][0] + style.padding[0][1], style.padding[1][0] + style.padding[1][1]}
}

ly_box :: proc(style: Ly_Constants, available: [2]Ly_Length, content: [2]i32) -> (out: [2]i32) #no_bounds_check {
	return {
		ly_length(ly_evaluate_length(style.size[0], available[0])) or_else (content[0] + style.padding[0][0] + style.padding[0][1]),
		ly_length(ly_evaluate_length(style.size[1], available[1])) or_else (content[1] + style.padding[1][0] + style.padding[1][1]),
	}
}

ly_position_flexbox :: proc(node: ^Ly_Node) {
	mx, cx := ly_axes(node.style.flow)

	// TODO: We could use SIMD swizzling here, with styles and measure as one vector.
	node_inner_pos := [Ly_Axis]i32 {
		.Main  = node.measure.pos[int(mx)] + node.style.padding[int(mx)][0],
		.Cross = node.measure.pos[int(cx)] + node.style.padding[int(cx)][0],
	}
	node_inner_size := [Ly_Axis]i32 {
		.Main  = node.measure.size[int(mx)] - node.style.padding[int(mx)][0] - node.style.padding[int(mx)][1],
		.Cross = node.measure.size[int(cx)] - node.style.padding[int(cx)][0] - node.style.padding[int(cx)][1],
	}

	flex_line: i32
	for child := node.first; child != nil; child = child.next {
		// This is the world-space top-left corner of the child's inner box.
		child_pos: [Ly_Axis]i32
		child_size := [Ly_Axis]i32 {
			.Main  = child.measure.size[int(mx)],
			.Cross = child.measure.size[int(cx)],
		}
		child_margin_start := [Ly_Axis]i32 {
			.Main  = child.style.margin[int(mx)][0],
			.Cross = child.style.margin[int(cx)][0],
		}
		child_margin_end := [Ly_Axis]i32 {
			.Main  = child.style.margin[int(mx)][1],
			.Cross = child.style.margin[int(cx)][1],
		}
		child_outer_size := child_size + child_margin_start + child_margin_end

		// Position on the main axis.
		// TODO: Benchmark "flex_line*0" over a branch.
		switch node.style.justify_content {
		case .FlexStart:
			if !child.style.absolute {
				child_pos[.Main] = node_inner_pos[.Main] + child_margin_start[.Main] + flex_line
			} else {
				child_pos[.Main] = node_inner_pos[.Main] + child_margin_start[.Main]
			}
		case .FlexEnd:
			if !child.style.absolute {
				child_pos[.Main] = node_inner_pos[.Main] + node_inner_size[.Main] - node.measure.content[.Main] + child_margin_start[.Main] + flex_line
			} else {
				child_pos[.Main] = node_inner_pos[.Main] + node_inner_size[.Main] - child_size[.Main] - child_margin_end[.Main]
			}
		case .Center:
			if !child.style.absolute {
				child_pos[.Main] = node_inner_pos[.Main] + node_inner_size[.Main] / 2 - node.measure.content[.Main] / 2 + child_margin_start[.Main] + flex_line
			} else {
				child_pos[.Main] = node_inner_pos[.Main] + node_inner_size[.Main] / 2 - child_outer_size[.Main] / 2 + child_margin_start[.Main]
			}
		}

		// Move along the main axis.
		if !child.style.absolute {
			flex_line += child_outer_size[.Main] + node.style.gap
		}

		// Position on the cross axis.
		switch node.style.align_items {
		case .Stretch:
			child_pos[.Cross] = node_inner_pos[.Cross] + child_margin_start[.Cross]

			if child.style.size[int(cx)] == nil {
				child_size[.Cross] = node_inner_size[.Cross]
			}
		case .FlexStart:
			child_pos[.Cross] = node_inner_pos[.Cross] + child_margin_start[.Cross]
		case .FlexEnd:
			child_pos[.Cross] = node_inner_pos[.Cross] + node_inner_size[.Cross] - child_size[.Cross] - child_margin_end[.Cross]
		case .Center:
			child_pos[.Cross] = node_inner_pos[.Cross] + node_inner_size[.Cross] / 2 - child_outer_size[.Cross] / 2 + child.style.margin[int(cx)][0]
		}

		child.measure.pos = {child_pos[mx], child_pos[cx]}
		child.measure.size = {child_size[mx], child_size[cx]}

		ly_position_flexbox(child)
	}
}

ly_sizing_flexbox :: proc(node: ^Ly_Node, available: [2]Ly_Length) {
	if node.style.measure_func != nil {
		node.measure.size = node.style.measure_func(node, available)
		return
	}

	mx, cx := ly_axes(node.style.flow)

	content: [Ly_Axis]i32
	sizing: {
		available_inner := ly_available_inner(node.style, available)

		child_count: i32 = 0
		any_grow: bool
		for child := node.first; child != nil; child = child.next {
			any_grow ||= child.style.grow
			(child.style.grow == false) or_continue

			ly_sizing_flexbox(child, available_inner)

			if !child.style.absolute {
				defer child_count += 1

				outer := ly_outer(child.style, child.measure.size)
				content[.Main] += outer[int(mx)]
				content[.Cross] = max(content[.Cross], outer[int(cx)])
			}
		}

		content[.Main] += node.style.gap * max(0, child_count - 1)

		(any_grow) or_break sizing

		free_mx: i32
		if length, ok := ly_length(available_inner[int(mx)]); ok {
			free_mx = length - content[.Main]
		}

		for child := node.first; child != nil; child = child.next {
			(child.style.absolute == false) or_continue
			(child.style.grow == true) or_continue

			// TODO: Passing size here is a hack.
			available_inner[int(mx)] = Ly_Length(free_mx)
			child.style.size[int(mx)] = 1.0

			ly_sizing_flexbox(child, available_inner)
			content[.Main] += child.measure.size[int(mx)]
			content[.Cross] = max(content[.Cross], child.measure.size[int(cx)])
		}
	}

	// Translate from flow space back into world.
	node.measure.size = ly_box(node.style, available, {content[mx], content[cx]})
	node.measure.content = content
}

ly_compute_flexbox_layout :: proc(node: ^Ly_Node, available: [2]Ly_Length) {
	ly_sizing_flexbox(node, available)
	node.measure.pos = {node.style.margin[0][0], node.style.margin[1][0]}
	ly_position_flexbox(node)
}
