#+private
package main

// MIT License
// 
// Copyright (c) Facebook, Inc. and its affiliates.
// 
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// 
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
// 
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import "base:runtime"
import "core:container/queue"
import "core:fmt"
import "core:math"
import "core:strings"
import "core:terminal/ansi"
import "core:testing"

import "lib:yoga"

@(private = "file", deferred_out = yoga.NodeFreeRecursive)
yoga_tree :: proc(user: ^Ly_Node, loc := #caller_location) -> yoga.Node_Ref {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	// We can pass a logger via YGConfig, but the output looks to be not useful.
	// Mostly fatal asserts for missing params.
	node := yoga.NodeNew()
	yoga.NodeSetContext(node, user)

	q: queue.Queue(yoga.Node_Ref)
	queue.init(&q, allocator = context.temp_allocator)

	parent := node
	for {
		index: uint
		for user := (^Ly_Node)(yoga.NodeGetContext(parent)).first; user != nil; user = user.next {
			defer index += 1

			node := yoga.NodeNew()
			yoga.NodeSetContext(node, user)
			yoga.NodeInsertChild(parent, node, index)

			queue.append(&q, node)
		}
		parent = queue.pop_front_safe(&q) or_break
	}

	return node
}

@(private = "file")
yoga_style :: proc(node: yoga.Node_Ref, style: Ly_Constants) {
	// Size.
	{
		// Width.
		switch value in style.size.x {
		case i32:
			yoga.NodeStyleSetWidth(node, f32(value))
		case f32:
			yoga.NodeStyleSetWidthPercent(node, value * 100)
		case nil:
			yoga.NodeStyleSetWidthAuto(node)
		}
		// Height.
		switch value in style.size.y {
		case i32:
			yoga.NodeStyleSetHeight(node, f32(value))
		case f32:
			yoga.NodeStyleSetHeightPercent(node, value * 100)
		case nil:
			yoga.NodeStyleSetHeightAuto(node)
		}
	}
	// Padding.
	for edge, i in ([?]yoga.Edge{.Left, .Right, .Top, .Bottom}) {
		yoga.NodeStyleSetPadding(node, edge, f32(style.padding_flat[i]))
	}
	// Margin.
	for edge, i in ([?]yoga.Edge{.Left, .Right, .Top, .Bottom}) {
		yoga.NodeStyleSetMargin(node, edge, f32(style.margin_flat[i]))
	}
	// Gap.
	yoga.NodeStyleSetGap(node, .All, f32(style.gap))
	// Align.
	{
		align: yoga.Align
		switch style.align_items {
		case .Stretch:
			align = .Stretch
		case .FlexStart:
			align = .FlexStart
		case .FlexEnd:
			align = .FlexEnd
		case .Center:
			align = .Center
		}
		yoga.NodeStyleSetAlignItems(node, align)
	}
	// Justify.
	{
		justify: yoga.Justify
		switch style.justify_content {
		case .FlexStart:
			justify = .FlexStart
		case .FlexEnd:
			justify = .FlexEnd
		case .Center:
			justify = .Center
		}
		yoga.NodeStyleSetJustifyContent(node, justify)
	}
	// Dir.
	{
		dir: yoga.Flex_Direction
		switch style.flow {
		case .Row:
			dir = .Row
		case .Col:
			dir = .Column
		case .RowReverse:
			dir = .RowReverse
		case .ColReverse:
			dir = .ColumnReverse
		}
		yoga.NodeStyleSetFlexDirection(node, dir)
	}
	// Absolute.
	yoga.NodeStyleSetPositionType(node, style.absolute ? .Absolute : .Relative)
}

@(private = "file")
yoga_validate :: proc(t: ^testing.T, node: yoga.Node_Ref, available: [2]Ly_Length, loc := #caller_location) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	// Copy styles.
	{
		q: queue.Queue(yoga.Node_Ref)
		queue.init(&q, allocator = context.temp_allocator)

		node := node
		for {
			user := (^Ly_Node)(yoga.NodeGetContext(node))
			yoga_style(node, user.style)

			for i in 0 ..< yoga.NodeGetChildCount(node) {
				queue.append(&q, yoga.NodeGetChild(node, i))
			}
			node = queue.pop_front_safe(&q) or_break
		}
	}

	// Calculate layout.
	{

		conv :: proc(length: Ly_Length) -> f32 {
			if value, ok := ly_length(length); ok {
				return f32(value)
			} else {
				// YGUndefined.
				return math.nan_f32()
			}
		}
		yoga.NodeCalculateLayout(node, conv(available.x), conv(available.y), .LTR)
	}

	// Verify attributes.
	{
		COLOR_ERROR :: ansi.CSI + ansi.FG_RED + ansi.SGR
		COLOR_CORRECTION :: ansi.CSI + ansi.FG_BRIGHT_CYAN + ansi.SGR
		COLOR_IGNORE :: ansi.CSI + ansi.FG_BRIGHT_BLACK + ansi.SGR
		COLOR_RESET :: ansi.CSI + ansi.RESET + ansi.SGR

		write_indent :: proc(buf: ^strings.Builder, depth: int) {
			for i in 0 ..< depth {
				strings.write_byte(buf, '\t')
			}
		}
		write_check :: proc(buf: ^strings.Builder, depth: int, name: string, value: $T, expected: T) -> (ok: bool) {
			use_color := .Terminal_Color in context.logger.options
			ok = value == expected

			write_indent(buf, depth)
			fmt.sbprintf(buf, "%v:\t", name)
			if !ok {
				if use_color {
					fmt.sbprint(buf, COLOR_ERROR)
				}
			}
			fmt.sbprintf(buf, "%v", value)
			if !ok {
				if use_color {
					fmt.sbprint(buf, COLOR_CORRECTION)
				}
				fmt.sbprintf(buf, "\t->%v", expected)
				if use_color {
					fmt.sbprint(buf, COLOR_RESET)
				}
			}
			fmt.sbprint(buf, '\n')

			return
		}
		write_meta :: proc(buf: ^strings.Builder, depth: int, name: string, value: $T) {
			use_color := .Terminal_Color in context.logger.options

			write_indent(buf, depth)
			if use_color {
				fmt.sbprint(buf, COLOR_IGNORE)
			}
			fmt.sbprintf(buf, "%v:\t%v", name, value)
			if use_color {
				fmt.sbprint(buf, COLOR_RESET)
			}
			fmt.sbprint(buf, '\n')
		}

		buf: strings.Builder
		strings.builder_init(&buf, context.temp_allocator)
		strings.write_byte(&buf, '\n')

		Pack :: struct {
			node:   yoga.Node_Ref,
			offset: [2]f32,
			depth:  int,
		}
		q: queue.Queue(Pack)
		queue.init(&q, allocator = context.temp_allocator)

		ok := true
		pack: Pack = {node, 0, 1}
		for {
			node, offset, depth := expand_values(pack)
			user := cast(^Ly_Node)yoga.NodeGetContext(node)

			pos := offset + {yoga.NodeLayoutGetLeft(node), yoga.NodeLayoutGetTop(node)}

			write_indent(&buf, depth)
			fmt.sbprintfln(&buf, "--")

			// Using "&&=" will cause a short circuit.
			// We want these checks to run on all nodes, even if we're already encountered a failure.
			ok &= write_check(&buf, depth, "pos0", f32(user.measure.pos[0]), pos[0])
			ok &= write_check(&buf, depth, "pos1", f32(user.measure.pos[1]), pos[1])
			ok &= write_check(&buf, depth, "size0", f32(user.measure.size[0]), yoga.NodeLayoutGetWidth(node))
			ok &= write_check(&buf, depth, "size1", f32(user.measure.size[1]), yoga.NodeLayoutGetHeight(node))
			write_meta(&buf, depth, "flow", user.style.flow)
			write_meta(&buf, depth, "justc", user.style.justify_content)
			write_meta(&buf, depth, "aligi", user.style.align_items)
			write_meta(&buf, depth, "abs", user.style.absolute)
			write_meta(&buf, depth, "gap", user.style.gap)
			write_meta(&buf, depth, "padd", user.style.padding_flat)
			write_meta(&buf, depth, "marg", user.style.margin_flat)

			for i in 0 ..< yoga.NodeGetChildCount(node) {
				queue.append(&q, Pack{yoga.NodeGetChild(node, i), pos, depth + 1})
			}

			pack = queue.pop_front_safe(&q) or_break
		}

		testing.expect(t, ok, strings.to_string(buf))
	}
}

@(test)
test_percentage_width_height :: proc(t: ^testing.T) {
	root := new(Ly_Node, context.temp_allocator)
	root.style.flow = .Row
	root.style.size = {200, 200}

	root_child0 := new(Ly_Node, context.temp_allocator)
	root_child0.style.size = {0.3, 0.3}
	ly_node_insert(root, root_child0)

	ly_compute_flexbox_layout(root, {0, 0})
	yoga_validate(t, yoga_tree(root), {0, 0})
}

@(test)
test_auto_width :: proc(t: ^testing.T) {
	root := new(Ly_Node, context.temp_allocator)
	root.style.flow = .Row
	root.style.size = {nil, 50}

	root_child0 := new(Ly_Node, context.temp_allocator)
	root_child0.style.size = {50, 50}
	ly_node_insert(root, root_child0)

	root_child1 := new(Ly_Node, context.temp_allocator)
	root_child1.style.size = {50, 50}
	ly_node_insert(root, root_child1)

	root_child2 := new(Ly_Node, context.temp_allocator)
	root_child2.style.size = {50, 50}
	ly_node_insert(root, root_child2)

	ly_compute_flexbox_layout(root, {LY_UNDEFINED, LY_UNDEFINED})
	yoga_validate(t, yoga_tree(root), {LY_UNDEFINED, LY_UNDEFINED})
}

@(test)
test_auto_height :: proc(t: ^testing.T) {
	root := new(Ly_Node, context.temp_allocator)
	root.style.flow = .Col
	root.style.size = {50, nil}

	root_child0 := new(Ly_Node, context.temp_allocator)
	root_child0.style.size = {50, 50}
	ly_node_insert(root, root_child0)

	root_child1 := new(Ly_Node, context.temp_allocator)
	root_child1.style.size = {50, 50}
	ly_node_insert(root, root_child1)

	root_child2 := new(Ly_Node, context.temp_allocator)
	root_child2.style.size = {50, 50}
	ly_node_insert(root, root_child2)

	ly_compute_flexbox_layout(root, {LY_UNDEFINED, LY_UNDEFINED})
	yoga_validate(t, yoga_tree(root), {LY_UNDEFINED, LY_UNDEFINED})
}

@(test)
test_flex_direction_column_no_height :: proc(t: ^testing.T) {
	root := new(Ly_Node, context.temp_allocator)
	root.style.flow = .Col
	root.style.size = {100, nil}

	root_child0 := new(Ly_Node, context.temp_allocator)
	root_child0.style.size = {nil, 10}
	ly_node_insert(root, root_child0)

	root_child1 := new(Ly_Node, context.temp_allocator)
	root_child1.style.size = {nil, 10}
	ly_node_insert(root, root_child1)

	root_child2 := new(Ly_Node, context.temp_allocator)
	root_child2.style.size = {nil, 10}
	ly_node_insert(root, root_child2)

	ly_compute_flexbox_layout(root, {LY_UNDEFINED, LY_UNDEFINED})
	yoga_validate(t, yoga_tree(root), {LY_UNDEFINED, LY_UNDEFINED})
}

@(test)
test_flex_direction_column :: proc(t: ^testing.T) {
	root := new(Ly_Node, context.temp_allocator)
	root.style.flow = .Col
	root.style.size = {100, 100}

	root_child0 := new(Ly_Node, context.temp_allocator)
	root_child0.style.size = {nil, 10}
	ly_node_insert(root, root_child0)

	root_child1 := new(Ly_Node, context.temp_allocator)
	root_child1.style.size = {nil, 10}
	ly_node_insert(root, root_child1)

	root_child2 := new(Ly_Node, context.temp_allocator)
	root_child2.style.size = {nil, 10}
	ly_node_insert(root, root_child2)

	ly_compute_flexbox_layout(root, {LY_UNDEFINED, LY_UNDEFINED})
	yoga_validate(t, yoga_tree(root), {LY_UNDEFINED, LY_UNDEFINED})
}

@(test)
test_flex_direction_row :: proc(t: ^testing.T) {
	root := new(Ly_Node, context.temp_allocator)
	root.style.flow = .Row
	root.style.size = {100, 100}

	root_child0 := new(Ly_Node, context.temp_allocator)
	root_child0.style.size = {10, nil}
	ly_node_insert(root, root_child0)

	root_child1 := new(Ly_Node, context.temp_allocator)
	root_child1.style.size = {10, nil}
	ly_node_insert(root, root_child1)

	root_child2 := new(Ly_Node, context.temp_allocator)
	root_child2.style.size = {10, nil}
	ly_node_insert(root, root_child2)

	ly_compute_flexbox_layout(root, {LY_UNDEFINED, LY_UNDEFINED})
	yoga_validate(t, yoga_tree(root), {LY_UNDEFINED, LY_UNDEFINED})
}

@(test)
test_padding_no_size :: proc(t: ^testing.T) {
	root := new(Ly_Node, context.temp_allocator)
	root.style.flow = .Col
	root.style.padding = {10, 10}

	ly_compute_flexbox_layout(root, {LY_UNDEFINED, LY_UNDEFINED})
	yoga_validate(t, yoga_tree(root), {LY_UNDEFINED, LY_UNDEFINED})
}

@(test)
test_padding_container_match_child :: proc(t: ^testing.T) {
	root := new(Ly_Node, context.temp_allocator)
	root.style.flow = .Col
	root.style.padding = {10, 10}

	root_child0 := new(Ly_Node, context.temp_allocator)
	root_child0.style.size = {10, 10}
	ly_node_insert(root, root_child0)

	ly_compute_flexbox_layout(root, {LY_UNDEFINED, LY_UNDEFINED})
	yoga_validate(t, yoga_tree(root), {LY_UNDEFINED, LY_UNDEFINED})
}

// Custom (not from Yoga repo).
@(test)
test_custom_navbar :: proc(t: ^testing.T) {
	root := new(Ly_Node, context.temp_allocator)
	root.style.flow = .Col
	root.style.size = {1.0, 1.0}

	root_nav := new(Ly_Node, context.temp_allocator)
	root_nav.style.size = {1.0, nil}
	root_nav.style.padding = {32, 32}
	ly_node_insert(root, root_nav)

	root_content := new(Ly_Node, context.temp_allocator)
	root_content.style.flow = .Col
	root_content.style.size = {nil, nil}
	root_content.style.padding = {32, 32}
	root_content.style.gap = 8
	ly_node_insert(root, root_content)

	root_content_child0 := new(Ly_Node, context.temp_allocator)
	root_content_child0.style.size = {32, 32}
	ly_node_insert(root_content, root_content_child0)

	root_content_child1 := new(Ly_Node, context.temp_allocator)
	root_content_child1.style.size = {0.5, 100}
	ly_node_insert(root_content, root_content_child1)

	root_content_child2 := new(Ly_Node, context.temp_allocator)
	root_content_child2.style.size = {0.25, 120}
	ly_node_insert(root_content, root_content_child2)

	root_content_child3 := new(Ly_Node, context.temp_allocator)
	root_content_child3.style.size = {nil, 80}
	ly_node_insert(root_content, root_content_child3)

	ly_compute_flexbox_layout(root, {1920, 1080})
	yoga_validate(t, yoga_tree(root), {1920, 1080})
}

// Custom (not from Yoga repo).
@(test)
test_custom_padding_edge :: proc(t: ^testing.T) {
	root := new(Ly_Node, context.temp_allocator)
	root.style.size = {0.5, 1.0}

	root_child0 := new(Ly_Node, context.temp_allocator)
	root_child0.style.size = {256, 256}
	ly_node_insert(root, root_child0)

	for &axis in root.style.padding_flat[:] {
		axis = 32
		defer axis = 0

		ly_compute_flexbox_layout(root, {1920, 1080})
		yoga_validate(t, yoga_tree(root), {1920, 1080})
	}
}

// Custom (not from Yoga repo).
@(test)
test_custom_padding_edge_weirder :: proc(t: ^testing.T) {
	root := new(Ly_Node, context.temp_allocator)
	root.style.gap = 8
	root.style.size = {0.5, 1.0}

	root_child0 := new(Ly_Node, context.temp_allocator)
	root_child0.style.size = {256, 256}
	ly_node_insert(root, root_child0)

	root_child1 := new(Ly_Node, context.temp_allocator)
	root_child1.style.size = {64, 46}
	ly_node_insert(root, root_child1)

	for &axis in root.style.padding_flat[:] {
		axis = 32
		defer axis = 0

		ly_compute_flexbox_layout(root, {1920, 1080})
		yoga_validate(t, yoga_tree(root), {1920, 1080})
	}
}

// Custom (not from Yoga repo).
@(test)
test_custom_margin_edge :: proc(t: ^testing.T) {
	root := new(Ly_Node, context.temp_allocator)
	root.style.size = {0.5, 1.0}

	root_child0 := new(Ly_Node, context.temp_allocator)
	root_child0.style.size = {256, 256}
	ly_node_insert(root, root_child0)

	for &axis in root_child0.style.margin_flat[:] {
		axis = 32
		defer axis = 0

		ly_compute_flexbox_layout(root, {1920, 1080})
		yoga_validate(t, yoga_tree(root), {1920, 1080})
	}
}

// Custom (not from Yoga repo).
@(test)
test_custom_margin_edge_weirder :: proc(t: ^testing.T) {
	root := new(Ly_Node, context.temp_allocator)
	root.style.gap = 8
	root.style.size = {0.5, 1.0}

	root_child0 := new(Ly_Node, context.temp_allocator)
	root_child0.style.size = {256, 256}
	ly_node_insert(root, root_child0)

	root_child1 := new(Ly_Node, context.temp_allocator)
	root_child1.style.size = {64, 46}
	ly_node_insert(root, root_child1)

	for &axis in root_child0.style.margin_flat[:] {
		axis = 32
		defer axis = 0
		for &axis in root_child1.style.margin_flat[:] {
			axis = 32
			defer axis = 0

			ly_compute_flexbox_layout(root, {1920, 1080})
			yoga_validate(t, yoga_tree(root), {1920, 1080})
		}
	}
}

// Custom (not from Yoga repo).
@(test)
test_custom_margin_padding :: proc(t: ^testing.T) {
	root := new(Ly_Node, context.temp_allocator)
	root.style.gap = 8
	root.style.size = {0.5, 1.0}

	root_child0 := new(Ly_Node, context.temp_allocator)
	root_child0.style.size = {256, 256}
	ly_node_insert(root, root_child0)

	root_child1 := new(Ly_Node, context.temp_allocator)
	root_child1.style.size = {64, 46}
	ly_node_insert(root, root_child1)

	tree := yoga_tree(root)

	// Use prime numbers to avoid false positives if the implementation
	// were to swap the dimensions, multiply by 2, etc.
	for &axis in root_child0.style.margin_flat[:] {
		axis = 13
		defer axis = 0
		for &axis in root_child1.style.margin_flat[:] {
			axis = 17
			defer axis = 0
			for &axis in root_child0.style.padding_flat[:] {
				axis = 19
				defer axis = 0
				for &axis in root_child1.style.padding_flat[:] {
					axis = 23
					defer axis = 0

					ly_compute_flexbox_layout(root, {1920, 1080})
					yoga_validate(t, tree, {1920, 1080})
				}
			}
		}
	}
}

// Custom (not from Yoga repo).
@(test)
test_custom_margin_padding_align :: proc(t: ^testing.T) {
	root := new(Ly_Node, context.temp_allocator)
	root.style.gap = 8
	root.style.size = {0.5, 1.0}

	root_child0 := new(Ly_Node, context.temp_allocator)
	root_child0.style.size = {256, 256}
	ly_node_insert(root, root_child0)

	root_child1 := new(Ly_Node, context.temp_allocator)
	root_child1.style.size = {64, 46}
	ly_node_insert(root, root_child1)

	tree := yoga_tree(root)

	for &axis in root_child0.style.margin_flat[:] {
		axis = 32
		defer axis = 0
		for &axis in root_child1.style.margin_flat[:] {
			axis = 16
			defer axis = 0
			for &axis in root_child0.style.padding_flat[:] {
				axis = 8
				defer axis = 0
				for &axis in root_child1.style.padding_flat[:] {
					axis = 4
					defer axis = 0

					for align_items in Ly_Align {
						root.style.align_items = align_items
						for justify_content in Ly_Justify {
							root.style.justify_content = justify_content

							root.style.justify_content = .Center
							ly_compute_flexbox_layout(root, {1920, 1080})
							yoga_validate(t, tree, {1920, 1080})
						}
					}
				}
			}
		}
	}
}

// Custom (not from Yoga repo).
// This ensures gaps count don't subtract from hypothetical available content size,
// used in sizing %length nodes.
@(test)
test_custom_percent_padding :: proc(t: ^testing.T) {
	root := new(Ly_Node, context.temp_allocator)
	root.style.gap = 16
	root.style.size = {1.0, 1.0}

	root_child0 := new(Ly_Node, context.temp_allocator)
	root_child0.style.size = {0.25, 0.25}
	ly_node_insert(root, root_child0)

	root_child1 := new(Ly_Node, context.temp_allocator)
	root_child1.style.size = {0.5, 0.5}
	root_child1.style.padding = 16
	ly_node_insert(root, root_child1)

	ly_compute_flexbox_layout(root, {2048, 2048})
	yoga_validate(t, yoga_tree(root), {2048, 2048})
}

// Custom (not from Yoga repo).
@(test)
test_custom_absolute :: proc(t: ^testing.T) {
	root := new(Ly_Node, context.temp_allocator)
	root.style.gap = 8
	root.style.padding = 32
	root.style.size = {0.5, 1.0}

	root_child0 := new(Ly_Node, context.temp_allocator)
	root_child0.style.size = {256, 256}
	ly_node_insert(root, root_child0)

	root_child1 := new(Ly_Node, context.temp_allocator)
	root_child1.style.size = {64, 46}
	root_child1.style.absolute = true
	ly_node_insert(root, root_child1)

	root_child1_child0 := new(Ly_Node, context.temp_allocator)
	root_child1_child0.style.size = {32, 32}
	ly_node_insert(root_child1, root_child1_child0)

	root_child2 := new(Ly_Node, context.temp_allocator)
	root_child2.style.size = {64, 64}
	ly_node_insert(root, root_child2)

	for align_items in Ly_Align {
		root.style.align_items = align_items
		for justify_content in Ly_Justify {
			root.style.justify_content = justify_content

			for &axis in root_child0.style.margin_flat[:] {
				axis = 32
				defer axis = 0

				for &axis in root_child1.style.margin_flat[:] {
					axis = 32
					defer axis = 0

					ly_compute_flexbox_layout(root, {1920, 1080})
					yoga_validate(t, yoga_tree(root), {1920, 1080})
				}
			}
		}
	}
}

// Custom (not from Yoga repo).
@(test)
test_custom_negative_margin :: proc(t: ^testing.T) {
	root := new(Ly_Node, context.temp_allocator)
	root.style.gap = 8
	root.style.size = {0.5, 1.0}
	root.style.margin = -32

	root_child0 := new(Ly_Node, context.temp_allocator)
	root_child0.style.size = {256, 256}
	ly_node_insert(root, root_child0)

	root_child1 := new(Ly_Node, context.temp_allocator)
	root_child1.style.size = {1.0, 1.0}
	root_child1.style.absolute = true
	root_child1.style.margin = -32
	ly_node_insert(root, root_child1)

	ly_compute_flexbox_layout(root, {1920, 1080})
	yoga_validate(t, yoga_tree(root), {1920, 1080})
}
