#+private
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

import "core:testing"

@(test)
test_numbers :: proc(t: ^testing.T) {
	PRECISE_NUMBER_COUNT :: u32(17)
	for i in 0 ..< PRECISE_NUMBER_COUNT {
		round_up := sf_uint_to_float_round_up(i)
		round_down := sf_uint_to_float_round_down(i)
		testing.expect_value(t, round_up, i)
		testing.expect_value(t, round_down, i)
	}

	Number_Float_Up_Down :: struct {
		num, up, down: u32,
	}
	TEST_DATA :: [?]Number_Float_Up_Down{{17, 17, 16}, {118, 39, 38}, {1024, 64, 64}, {65536, 112, 112}, {529445, 137, 136}, {1048575, 144, 143}}

	for e in TEST_DATA {
		testing.expect_value(t, sf_uint_to_float_round_up(e.num), e.up)
		testing.expect_value(t, sf_uint_to_float_round_down(e.num), e.down)
	}
}

@(test)
test_numbers_again :: proc(t: ^testing.T) {
	PRECISE_NUMBER_COUNT :: u32(240)
	for i in 0 ..< PRECISE_NUMBER_COUNT {
		j := sf_float_to_uint(i)
		round_up := sf_uint_to_float_round_up(j)
		round_down := sf_uint_to_float_round_down(j)
		testing.expect_value(t, round_up, i)
		testing.expect_value(t, round_down, i)
	}
}

@(private)
SIZE_TEST :: 1024 * 1024 * 256

@(test)
test_basic :: proc(t: ^testing.T) {
	m: Offset_Allocator
	init(&m, SIZE_TEST, allocator = context.temp_allocator)
	defer destroy(&m)

	a := allocate(&m, 1337)
	testing.expect_value(t, a.offset, 0)
	testing.expect(t, m.free_storage < m.size)
	free(&m, a)
	testing.expect_value(t, m.free_storage, SIZE_TEST)
}

@(test)
test_allocate :: proc(t: ^testing.T) {
	m: Offset_Allocator
	init(&m, SIZE_TEST, allocator = context.temp_allocator)
	defer destroy(&m)

	{
		a := allocate(&m, 0)
		testing.expect_value(t, a.offset, 0)

		b := allocate(&m, 1)
		testing.expect_value(t, b.offset, 0)

		c := allocate(&m, 123)
		testing.expect_value(t, c.offset, 1)

		d := allocate(&m, 1234)
		testing.expect_value(t, d.offset, 124)

		free(&m, a)
		free(&m, b)
		free(&m, c)
		free(&m, d)

		validate_all := allocate(&m, SIZE_TEST)
		testing.expect_value(t, validate_all.offset, 0)
		free(&m, validate_all)
	}

	{
		a := allocate(&m, 1337)
		testing.expect_value(t, a.offset, 0)
		free(&m, a)

		b := allocate(&m, 1337)
		testing.expect_value(t, b.offset, 0)
		free(&m, b)

		validate_all := allocate(&m, SIZE_TEST)
		testing.expect_value(t, validate_all.offset, 0)
		free(&m, validate_all)
	}

	{

		a := allocate(&m, 1024)
		testing.expect_value(t, a.offset, 0)

		b := allocate(&m, 3456)
		testing.expect_value(t, b.offset, 1024)

		free(&m, a)

		c := allocate(&m, 1024)
		testing.expect_value(t, c.offset, 0)

		free(&m, c)
		free(&m, b)

		validate_all := allocate(&m, SIZE_TEST)
		testing.expect_value(t, validate_all.offset, 0)
		free(&m, validate_all)
	}

	{
		a := allocate(&m, 1024)
		testing.expect_value(t, a.offset, 0)

		b := allocate(&m, 3456)
		testing.expect_value(t, b.offset, 1024)

		free(&m, a)

		c := allocate(&m, 2345)
		testing.expect_value(t, c.offset, 1024 + 3456)

		d := allocate(&m, 456)
		testing.expect_value(t, d.offset, 0)

		e := allocate(&m, 512)
		testing.expect_value(t, e.offset, 456)

		report := storage_report(m)
		testing.expect_value(t, report.total_free_space, SIZE_TEST - 3456 - 2345 - 456 - 512)
		testing.expect(t, report.largest_free_region != report.total_free_space)

		free(&m, c)
		free(&m, d)
		free(&m, b)
		free(&m, e)

		validate_all := allocate(&m, SIZE_TEST)
		testing.expect_value(t, validate_all.offset, 0)
		free(&m, validate_all)
	}

	{
		allocations: [256]Allocation
		for &a, i in allocations {
			a = allocate(&m, 1024 * 1024)
			testing.expect_value(t, a.offset, u32(i) * 1024 * 1024)
		}

		report := storage_report(m)
		testing.expect_value(t, report.total_free_space, 0)
		testing.expect_value(t, report.largest_free_region, 0)

		free(&m, allocations[243])
		free(&m, allocations[5])
		free(&m, allocations[123])
		free(&m, allocations[95])

		free(&m, allocations[151])
		free(&m, allocations[152])
		free(&m, allocations[153])
		free(&m, allocations[154])


		allocations[243] = allocate(&m, 1024 * 1024)
		allocations[5] = allocate(&m, 1024 * 1024)
		allocations[123] = allocate(&m, 1024 * 1024)
		allocations[95] = allocate(&m, 1024 * 1024)
		allocations[151] = allocate(&m, 1024 * 1024 * 4)

		testing.expect(t, allocations[243].offset != NO_SPACE)
		testing.expect(t, allocations[5].offset != NO_SPACE)
		testing.expect(t, allocations[123].offset != NO_SPACE)
		testing.expect(t, allocations[95].offset != NO_SPACE)
		testing.expect(t, allocations[151].offset != NO_SPACE)

		for &e, i in allocations {
			if i < 152 || i > 154 {
				free(&m, e)
			}
		}

		report2 := storage_report(m)
		testing.expect_value(t, report2.total_free_space, SIZE_TEST)
		testing.expect_value(t, report2.largest_free_region, SIZE_TEST)

		validate_all := allocate(&m, SIZE_TEST)
		testing.expect_value(t, validate_all.offset, 0)
		free(&m, validate_all)
	}
}

// The allocator reserves a node as top-level, meaning the user only has n-1 slots.
// It causes this second allocation to fail!
// https://github.com/sebbbi/OffsetAllocator/issues/3.
// TODO: Do we care in practice?
@(test)
test_off_by_one_bug :: proc(t: ^testing.T) {
	m: Offset_Allocator
	init(&m, 256, 2, allocator = context.temp_allocator)
	defer destroy(&m)

	{
		a := allocate(&m, 32)
		testing.expect_value(t, a.offset, 0)

		b := allocate(&m, 32)
		testing.expect_value(t, b.index, INVALID_INDEX)

		free(&m, a)
	}
}

@(test)
test_reset :: proc(t: ^testing.T) {
	m: Offset_Allocator
	init(&m, SIZE_TEST, allocator = context.temp_allocator)
	defer destroy(&m)

	for _ in 0 ..= 1 {
		defer reset(&m)

		a := allocate(&m, 0)
		testing.expect_value(t, a.offset, 0)

		b := allocate(&m, 1)
		testing.expect_value(t, b.offset, 0)

		c := allocate(&m, 123)
		testing.expect_value(t, c.offset, 1)

		d := allocate(&m, 1234)
		testing.expect_value(t, d.offset, 124)

		free(&m, a)
		free(&m, b)
		free(&m, c)
		free(&m, d)

		validate_all := allocate(&m, SIZE_TEST)
		testing.expect_value(t, validate_all.offset, 0)
		free(&m, validate_all)
	}
}
