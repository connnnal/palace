package slot_array

// This is a cheap wrapper for allocating over a fixed array of existing items.

Handle :: bit_field u64 {
	idx: u32 | 32,
	gen: u32 | 32,
}

@(private)
Slot :: bit_field u64 {
	gen:   u32  | 32,
	next:  u32  | 31,
	alive: bool | 1,
}

@(private)
SLOT_HEAD_NEXT_MASK :: u32(1 << 31)

Slot_Array :: struct($C: u32) {
	// Freelist head.
	next_free: u32,
	// For initial linear allocation.
	use_count: u32,
	slots:     [C]Slot,
}

alloc :: proc(sm: ^$M/Slot_Array($C)) -> (Handle, bool) {
	idx: u32

	if next := sm.next_free; next & SLOT_HEAD_NEXT_MASK > 0 {
		idx = next & ~SLOT_HEAD_NEXT_MASK
	} else {
		idx = sm.use_count
		if idx >= C {
			// Slot array exhausted.
			return {}, false
		}
		sm.use_count += 1
	}

	#no_bounds_check slot := &sm.slots[idx]
	slot.alive = true
	slot.gen += 1
	return Handle{idx = idx, gen = slot.gen}, true
}

free :: proc(sm: ^$M/Slot_Array($C), handle: Handle) {
	slot := &sm.slots[handle.idx]

	if slot.alive && slot.gen == handle.gen {
		slot.alive = false

		slot.next = sm.next_free
		sm.next_free = handle.idx | SLOT_HEAD_NEXT_MASK
	}
}

get :: proc(sm: ^$M/Slot_Array($C), handle: Handle) -> (idx: int, ok: bool) {
	slot := &sm.slots[handle.idx]
	return int(handle.idx), slot.alive && slot.gen == handle.gen
}
