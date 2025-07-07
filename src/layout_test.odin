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

import "core:testing"

@(test)
test_percentage_width_height :: proc(t: ^testing.T) {
	root := new(Ly_Node, context.temp_allocator)
	root.style.flow = .Row
	root.style.size = {200, 200}

	root_child0 := new(Ly_Node, context.temp_allocator)
	root_child0.style.size = {0.3, 0.3}
	ly_node_insert(root, root_child0)

	ly_compute_flexbox_layout(root, {0, 0})

	testing.expect_value(t, root.measure.pos.x, 0)
	testing.expect_value(t, root.measure.pos.y, 0)
	testing.expect_value(t, root.measure.size.x, 200)
	testing.expect_value(t, root.measure.size.y, 200)

	testing.expect_value(t, root_child0.measure.pos.x, 0)
	testing.expect_value(t, root_child0.measure.pos.y, 0)
	testing.expect_value(t, root_child0.measure.size.x, 60)
	testing.expect_value(t, root_child0.measure.size.y, 60)
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

	ly_compute_flexbox_layout(root, {nil, nil})

	testing.expect_value(t, root.measure.pos.x, 0)
	testing.expect_value(t, root.measure.pos.y, 0)
	testing.expect_value(t, root.measure.size.x, 150)
	testing.expect_value(t, root.measure.size.y, 50)

	testing.expect_value(t, root_child0.measure.pos.x, 0)
	testing.expect_value(t, root_child0.measure.pos.y, 0)
	testing.expect_value(t, root_child0.measure.size.x, 50)
	testing.expect_value(t, root_child0.measure.size.y, 50)

	testing.expect_value(t, root_child1.measure.pos.x, 50)
	testing.expect_value(t, root_child1.measure.pos.y, 0)
	testing.expect_value(t, root_child1.measure.size.x, 50)
	testing.expect_value(t, root_child1.measure.size.y, 50)

	testing.expect_value(t, root_child2.measure.pos.x, 100)
	testing.expect_value(t, root_child2.measure.pos.y, 0)
	testing.expect_value(t, root_child2.measure.size.x, 50)
	testing.expect_value(t, root_child2.measure.size.y, 50)
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

	ly_compute_flexbox_layout(root, {nil, nil})

	testing.expect_value(t, root.measure.pos.x, 0)
	testing.expect_value(t, root.measure.pos.y, 0)
	testing.expect_value(t, root.measure.size.x, 50)
	testing.expect_value(t, root.measure.size.y, 150)

	testing.expect_value(t, root_child0.measure.pos.x, 0)
	testing.expect_value(t, root_child0.measure.pos.y, 0)
	testing.expect_value(t, root_child0.measure.size.x, 50)
	testing.expect_value(t, root_child0.measure.size.y, 50)

	testing.expect_value(t, root_child1.measure.pos.x, 0)
	testing.expect_value(t, root_child1.measure.pos.y, 50)
	testing.expect_value(t, root_child1.measure.size.x, 50)
	testing.expect_value(t, root_child1.measure.size.y, 50)

	testing.expect_value(t, root_child2.measure.pos.x, 0)
	testing.expect_value(t, root_child2.measure.pos.y, 100)
	testing.expect_value(t, root_child2.measure.size.x, 50)
	testing.expect_value(t, root_child2.measure.size.y, 50)
}
