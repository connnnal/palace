package offset_allocator

// MIT License
//
// Copyright (c) 2023 Sebastian Aaltonen
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

import "base:intrinsics"
import "base:runtime"
import "core:mem"

MANTISSA_BITS :: 3
MANTISSA_VALUE :: 1 << MANTISSA_BITS
MANTISSA_MASK :: MANTISSA_VALUE - 1

@(private)
lzcnt_nonzero :: intrinsics.count_leading_zeros
@(private)
tzcnt_nonzero :: intrinsics.count_trailing_zeros

@(private)
sf_uint_to_float_round_up :: proc(size: u32) -> u32 {
	exp, mantissa: u32

	if size < MANTISSA_VALUE {
		mantissa = size
	} else {
		leading_zeros := lzcnt_nonzero(size)
		highest_set_bit := 31 - leading_zeros

		mantissa_start_bit := highest_set_bit - MANTISSA_BITS
		exp = mantissa_start_bit + 1
		mantissa = (size >> mantissa_start_bit) & MANTISSA_MASK

		low_bits_mask: u32 = (1 << mantissa_start_bit) - 1

		if (size & low_bits_mask) != 0 {
			mantissa += 1
		}
	}

	return (exp << MANTISSA_BITS) + mantissa
}

@(private)
sf_uint_to_float_round_down :: proc(size: u32) -> u32 {
	exp, mantissa: u32

	if size < MANTISSA_VALUE {
		mantissa = size
	} else {
		leading_zeros := lzcnt_nonzero(size)
		highest_set_bit := 31 - leading_zeros

		mantissa_start_bit := highest_set_bit - MANTISSA_BITS
		exp = mantissa_start_bit + 1
		mantissa = (size >> mantissa_start_bit) & MANTISSA_MASK
	}

	return (exp << MANTISSA_BITS) | mantissa
}

@(private)
sf_float_to_uint :: proc(float_value: u32) -> u32 {
	exponent := float_value >> MANTISSA_BITS
	mantissa := float_value & MANTISSA_MASK

	if exponent == 0 {
		return mantissa
	} else {
		return (mantissa | MANTISSA_VALUE) << (exponent - 1)
	}
}

NO_SPACE :: max(u32)

@(private)
find_lowest_set_bit_after :: proc(bit_mask: u32, start_bit_index: u32) -> u32 {
	mask_before_start_index: u32 = (1 << start_bit_index) - 1
	mask_after_start_index := ~mask_before_start_index
	bits_after := bit_mask & mask_after_start_index
	if (bits_after == 0) {return NO_SPACE}
	return tzcnt_nonzero(bits_after)
}

NUM_TOP_BINS :: 32
BINS_PER_LEAF :: 8
TOP_BINS_INDEX_SHIFT :: 3
LEAF_BINS_INDEX_MASK :: 0x7
NUM_LEAF_BINS :: NUM_TOP_BINS * BINS_PER_LEAF

// Node_Index :: distinct u32
Node_Index :: distinct u16
INVALID_INDEX :: max(Node_Index)

Node :: struct {
	data_offset, data_size:                                     u32,
	// TODO: Algorithm expects initialisation as "UNUSED". Expect zero instead.
	bin_list_prev, bin_list_next, neighbor_prev, neighbor_next: Node_Index,
	used:                                                       bool,
	// using inner:                                                bit_field u32 {
	// 	data_size: u32  | 31,
	// 	used:      bool | 1,
	// },
}
NODE_DEFAULT :: Node{0, 0, INVALID_INDEX, INVALID_INDEX, INVALID_INDEX, INVALID_INDEX, false}

Offset_Allocator :: struct {
	size:          u32,
	max_allocs:    u32,
	free_storage:  u32,
	used_bins_top: u32,
	nodes:         []Node,
	free_nodes:    []Node_Index,
	free_offset:   u32,
	allocator:     runtime.Allocator, // Solely used for init/teardown.
	used_bins:     [NUM_TOP_BINS]u8,
	bin_indices:   [NUM_LEAF_BINS]Node_Index,
}

Allocation :: struct {
	offset: u32,
	index:  Node_Index,
}

Storage_Report :: struct {
	total_free_space, largest_free_region: u32,
}

Storage_Report_Full_Region :: struct {
	size, count: u32,
}

Storage_Report_Full :: struct {
	free_regions: [NUM_LEAF_BINS]Storage_Report_Full_Region,
}

init :: proc(m: ^Offset_Allocator, size: u32, max_allocs: u32 = 128 * 1024, allocator := context.allocator) {
	m.size = size
	m.max_allocs = max_allocs

	m.allocator = allocator
	m.nodes = make([]Node, m.max_allocs, allocator)
	m.free_nodes = make([]Node_Index, m.max_allocs, allocator)

	reset(m)
}

destroy :: proc(m: ^Offset_Allocator) {
	delete(m.nodes, allocator = m.allocator)
	delete(m.free_nodes, allocator = m.allocator)
}

reset :: proc(m: ^Offset_Allocator) {
	m.free_storage = 0
	m.used_bins_top = 0
	m.free_offset = m.max_allocs - 1

	mem.zero_slice(m.used_bins[:])

	m.bin_indices = INVALID_INDEX

	// TODO: Upstream performs node initialisation, but I think it's redundant here?
	// for &n in m.nodes {
	// 	n = NODE_DEFAULT
	// }

	for &e, i in m.free_nodes {
		e = Node_Index(m.max_allocs - u32(i) - 1)
	}

	insert_node_into_bin(m, m.size, 0)
}

allocate :: proc(m: ^Offset_Allocator, size: u32) -> (Allocation, bool) #optional_ok {
	assert(m.size != 0)

	// Upstream catches spent allocator with "== 0" check, which fails trying to allocate the last node.
	// Because "free_offset" is unsigned, we use "max(type)" instead to catch the underflow.
	// https://github.com/sebbbi/OffsetAllocator/issues/3#issuecomment-2294463807.
	if m.free_offset == ~u32(0) {
		return {NO_SPACE, INVALID_INDEX}, false
	}

	min_bin_index := sf_uint_to_float_round_up(size)

	min_top_bin_index := min_bin_index >> TOP_BINS_INDEX_SHIFT
	min_leaf_bin_index := min_bin_index & LEAF_BINS_INDEX_MASK

	top_bin_index := min_top_bin_index
	leaf_bin_index := NO_SPACE

	if m.used_bins_top & (1 << top_bin_index) != 0 {
		leaf_bin_index = find_lowest_set_bit_after(cast(u32)m.used_bins[top_bin_index], min_leaf_bin_index)
	}

	if leaf_bin_index == NO_SPACE {
		top_bin_index = find_lowest_set_bit_after(m.used_bins_top, min_top_bin_index + 1)

		if top_bin_index == NO_SPACE {
			return {NO_SPACE, INVALID_INDEX}, false
		}

		leaf_bin_index = tzcnt_nonzero(cast(u32)m.used_bins[top_bin_index])
	}

	bin_index := (top_bin_index << TOP_BINS_INDEX_SHIFT) | leaf_bin_index
	assert(bin_index < NUM_LEAF_BINS)

	node_index := m.bin_indices[bin_index]
	node := &m.nodes[node_index]
	node_total_size := node.data_size
	node.data_size = size
	node.used = true
	m.bin_indices[bin_index] = node.bin_list_next

	if (node.bin_list_next != INVALID_INDEX) {m.nodes[node.bin_list_next].bin_list_prev = INVALID_INDEX}

	assert(m.free_storage >= node_total_size)
	m.free_storage -= node_total_size

	if m.bin_indices[bin_index] == INVALID_INDEX {
		m.used_bins[top_bin_index] &= ~(1 << leaf_bin_index)

		if m.used_bins[top_bin_index] == 0 {
			m.used_bins_top &= ~(1 << top_bin_index)
		}
	}

	assert(node_total_size >= size)
	remainder_size := node_total_size - size
	if remainder_size > 0 {
		new_node_index := insert_node_into_bin(m, remainder_size, node.data_offset + size)

		if (node.neighbor_next != INVALID_INDEX) {m.nodes[node.neighbor_next].neighbor_prev = new_node_index}
		m.nodes[new_node_index].neighbor_prev = node_index
		m.nodes[new_node_index].neighbor_next = node.neighbor_next
		node.neighbor_next = new_node_index
	}

	return {node.data_offset, node_index}, true
}

free :: proc(m: ^Offset_Allocator, allocation: Allocation) {
	assert(allocation.index != INVALID_INDEX)
	assert(m.nodes != nil)

	node_index := allocation.index
	node := &m.nodes[node_index]

	assert(node.used == true)

	offset := node.data_offset
	size := node.data_size

	assert(node.neighbor_prev != node_index)
	if (node.neighbor_prev != INVALID_INDEX) && !m.nodes[node.neighbor_prev].used {
		prev_node := &m.nodes[node.neighbor_prev]
		offset = prev_node.data_offset
		size += prev_node.data_size

		remove_node_from_bin(m, node.neighbor_prev)

		assert(prev_node.neighbor_next == node_index)
		node.neighbor_prev = prev_node.neighbor_prev
	}

	assert(node.neighbor_next != node_index)
	if (node.neighbor_next != INVALID_INDEX) && !m.nodes[node.neighbor_next].used {
		next_node := &m.nodes[node.neighbor_next]
		size += next_node.data_size

		remove_node_from_bin(m, node.neighbor_next)

		assert(next_node.neighbor_prev == node_index)
		node.neighbor_next = next_node.neighbor_next
	}

	neighbor_next := node.neighbor_next
	neighbor_prev := node.neighbor_prev

	assert(m.free_offset + 1 < m.max_allocs)
	m.free_offset += 1
	m.free_nodes[m.free_offset] = node_index

	combined_node_index := insert_node_into_bin(m, size, offset)

	if neighbor_next != INVALID_INDEX {
		m.nodes[combined_node_index].neighbor_next = neighbor_next
		m.nodes[neighbor_next].neighbor_prev = combined_node_index
	}
	if neighbor_prev != INVALID_INDEX {
		m.nodes[combined_node_index].neighbor_prev = neighbor_prev
		m.nodes[neighbor_prev].neighbor_next = combined_node_index
	}
}

insert_node_into_bin :: proc(m: ^Offset_Allocator, size: u32, data_offset: u32) -> Node_Index {
	bin_index := sf_uint_to_float_round_down(size)
	assert(bin_index < NUM_LEAF_BINS)

	top_bin_index := bin_index >> TOP_BINS_INDEX_SHIFT
	leaf_bin_index := bin_index & LEAF_BINS_INDEX_MASK

	if m.bin_indices[bin_index] == INVALID_INDEX {
		m.used_bins[top_bin_index] |= 1 << leaf_bin_index
		m.used_bins_top |= 1 << top_bin_index
	}

	top_node_index := m.bin_indices[bin_index]
	assert(m.free_offset < m.max_allocs)
	node_index := m.free_nodes[m.free_offset]
	m.free_offset -= 1

	m.nodes[node_index] = NODE_DEFAULT
	m.nodes[node_index].data_offset = data_offset
	m.nodes[node_index].data_size = size
	m.nodes[node_index].bin_list_next = top_node_index

	if top_node_index != INVALID_INDEX {
		m.nodes[top_node_index].bin_list_prev = node_index
	}

	m.bin_indices[bin_index] = node_index

	m.free_storage += size

	return node_index
}

remove_node_from_bin :: proc(m: ^Offset_Allocator, node_index: Node_Index) {
	node := &m.nodes[node_index]

	if node.bin_list_prev != INVALID_INDEX {
		m.nodes[node.bin_list_prev].bin_list_next = node.bin_list_next
		if node.bin_list_next != INVALID_INDEX {m.nodes[node.bin_list_next].bin_list_prev = node.bin_list_prev}
	} else {
		bin_index := sf_uint_to_float_round_down(node.data_size)

		top_bin_index := bin_index >> TOP_BINS_INDEX_SHIFT
		leaf_bin_index := bin_index & LEAF_BINS_INDEX_MASK

		m.bin_indices[bin_index] = node.bin_list_next
		if (node.bin_list_next != INVALID_INDEX) {m.nodes[node.bin_list_next].bin_list_prev = INVALID_INDEX}

		if m.bin_indices[bin_index] == INVALID_INDEX {
			m.used_bins[top_bin_index] &= ~(1 << leaf_bin_index)

			if m.used_bins[top_bin_index] == 0 {
				m.used_bins_top &= ~(1 << top_bin_index)
			}
		}
	}

	assert(m.free_offset + 1 < m.max_allocs)
	m.free_offset += 1
	m.free_nodes[m.free_offset] = node_index

	m.free_storage -= node.data_size
}

storage_report :: proc(m: Offset_Allocator) -> Storage_Report {
	free_storage := m.free_storage
	largest_free_region := m.free_storage

	if m.free_offset != 0 {
		if m.used_bins_top != 0 {
			top_bin_index := 31 - lzcnt_nonzero(m.used_bins_top)
			leaf_bin_index := 7 - lzcnt_nonzero(m.used_bins[top_bin_index])
			largest_free_region = sf_float_to_uint((top_bin_index << TOP_BINS_INDEX_SHIFT) | u32(leaf_bin_index))
			assert(free_storage >= largest_free_region)
		}
	}

	return {free_storage, largest_free_region}
}

storage_report_full :: proc(m: Offset_Allocator) -> (r: Storage_Report_Full) {
	for i in 0 ..< u32(NUM_LEAF_BINS) {
		count: u32
		node_index := m.bin_indices[i]
		for node_index != INVALID_INDEX {
			node_index = m.nodes[node_index].bin_list_next
			count += 1
		}
		r.free_regions[i] = {sf_float_to_uint(i), count}
	}
	return
}
