package virtual_array

import "base:intrinsics"
import "core:mem"
import "core:mem/virtual"
import "core:slice"

RESERVE_SIZE :: mem.Megabyte * 64
COMMIT_SIZE :: mem.Kilobyte * 64
#assert(COMMIT_SIZE <= RESERVE_SIZE)

FREE_TYPE :: distinct int
FREE_INVALID :: ~FREE_TYPE{}

Virtual_Array :: struct($T: typeid) #no_copy where size_of(T) <= COMMIT_SIZE,
	size_of(T) >= size_of(FREE_TYPE) {
	tide:        uintptr, // Where we've committed up to.
	cursor:      uintptr, // Where we want to place our next item in memory.
	buf:         [^]struct #raw_union {
		item: T,
		next: FREE_TYPE,
	},
	count, free: FREE_TYPE,
}

@(private)
align_forward_uintptr :: proc "contextless" ($ptr: uintptr, $align: uintptr) -> uintptr {
	return (ptr + align - 1) & ~(align - 1)
}

alloc :: proc "contextless" (va: ^$A/Virtual_Array($T), zero := true) -> (^T, int) #no_bounds_check {
	if va.buf == nil {
		@(cold)
		init :: #force_no_inline proc "contextless" (va: ^$A/Virtual_Array($T)) {
			buf, _err := virtual.reserve(RESERVE_SIZE)
			va.buf = auto_cast raw_data(buf)

			va.tide = uintptr(va.buf)
			va.cursor = uintptr(va.buf)
			va.count = 0
			va.free = FREE_INVALID
		}
		init(va)
	} else if idx := va.free; idx != FREE_INVALID {
		// Try to take from our inline freelist.	
		slot := &va.buf[idx]
		va.free = slot.next
		if zero {mem.zero_item(&slot.item)}
		return &slot.item, int(idx)
	}

	// Reserve a new chunk if we've run out of space.
	// Note this isn't a loop, because we require the type to be no larger than the commit chunk.
	width := align_forward_uintptr(size_of(T), align_of(T))
	if va.cursor + width > va.tide {
		@(cold)
		grow :: #force_no_inline proc "contextless" (va: ^$A/Virtual_Array($T)) {
			assert_contextless(va.tide - uintptr(va.buf) < RESERVE_SIZE, "at capacity")
			err := virtual.commit(cast(rawptr)va.tide, COMMIT_SIZE)
			assert_contextless(err == nil, "failed to reserve block")
			va.tide += COMMIT_SIZE
		}
		grow(va)
	}

	defer va.cursor += width
	defer va.count += 1
	return cast(^T)va.cursor, int(va.count)
}

// This releases memory.
// Container can be reused for new allocations!
destroy :: #force_inline proc "contextless" (va: ^$A/Virtual_Array($T)) {
	virtual.release(va.buf, RESERVE_SIZE)
	va.buf = nil
}

// This doesn't release memory.
clear :: #force_inline proc "contextless" (va: ^$A/Virtual_Array($T)) {
	va.cursor = uintptr(va.buf)
	va.count = 0
	va.free = FREE_INVALID
}

get :: #force_inline proc "contextless" (va: ^$A/Virtual_Array($T), #any_int idx: FREE_TYPE) -> (^T, bool) #no_bounds_check {
	return &va.buf[idx].item, idx >= 0 && idx < va.count
}

as_slice :: #force_inline proc "contextless" (va: ^$A/Virtual_Array($T)) -> []T #no_bounds_check {
	assert_contextless(va.free == FREE_INVALID, "virtual array has freelist holes, can't make a contiguous slice")
	return va.buf[:va.count]
}

free_index :: #force_inline proc "contextless" (va: ^$A/Virtual_Array($T), #any_int idx: FREE_TYPE) {
	assert_contextless(idx >= 0 && idx < va.count)
	// Insert element at front of the free linked list.
	va.buf[idx].next = va.free
	va.free = idx
}

free_item :: #force_inline proc "contextless" (va: ^$A/Virtual_Array($T), item: ^T) #no_bounds_check {
	idx := intrinsics.ptr_sub(item, raw_data(&va.buf))
	free_index(va, idx)
}
