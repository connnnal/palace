package main

import "core:log"

import d3d12 "vendor:directx/d3d12"

import oa "lib:offset_allocator"
import sa "slot_array"

Gfx_Descriptor_Handle :: struct($T: d3d12.DESCRIPTOR_HEAP_TYPE, $C: u32) #raw_union {
	slot:       sa.Handle,
	allocation: oa.Allocation,
}

Gfx_Descriptor_Heap :: struct {
	// Info.
	resource:  ^d3d12.IDescriptorHeap,
	start_cpu: d3d12.CPU_DESCRIPTOR_HANDLE,
	start_gpu: d3d12.GPU_DESCRIPTOR_HANDLE,
	inc:       u32,
	// Resource tracking.
	slots:     sa.Slot_Array(GFX_DESCRIPTOR_SLOTS_UPPER),
	heap:      oa.Offset_Allocator,
}

gfx_descriptor: struct {
	heaps: [d3d12.DESCRIPTOR_HEAP_TYPE]Gfx_Descriptor_Heap,
}

Gfx_Descriptor_Spec :: struct {
	count_slots, count_heap: int,
}
GFX_DESCRIPTOR_SPECS :: [d3d12.DESCRIPTOR_HEAP_TYPE]Gfx_Descriptor_Spec {
	.CBV_SRV_UAV = {1024, 1024},
	.DSV         = {16, 0},
	.RTV         = {16, 0},
	.SAMPLER     = {0, 0},
}
GFX_DESCRIPTOR_SLOTS_UPPER :: 1024
GFX_DESCRIPTOR_HEAP_ALLOC_COUNT :: 32

gfx_descriptor_init :: proc() {
	specs := GFX_DESCRIPTOR_SPECS
	for &heap, type in gfx_descriptor.heaps {
		// Some descriptor types may go unused.
		count_slots, count_heap := expand_values(specs[type])
		(count_slots + count_heap > 0) or_continue

		gpu_visible := type == .CBV_SRV_UAV

		hr := gfx_state.device->CreateDescriptorHeap(
			&{Type = type, NumDescriptors = u32(count_slots + count_heap), Flags = gpu_visible ? {.SHADER_VISIBLE} : {}},
			d3d12.IDescriptorHeap_UUID,
			(^rawptr)(&heap.resource),
		)
		checkf(hr, "failed to create descriptor heap %q", type)

		heap.resource->GetCPUDescriptorHandleForHeapStart(&heap.start_cpu)
		if gpu_visible {
			heap.resource->GetGPUDescriptorHandleForHeapStart(&heap.start_gpu)
		}

		heap.inc = gfx_state.device->GetDescriptorHandleIncrementSize(type)

		if count_slots > 0 {
			// Initialize the slot allocator.
			// TODO: Runtime-variable-length slot allocator.
		}
		if count_heap > 0 {
			// Initialize the heap allocator.
			oa.init(&heap.heap, u32(count_heap), GFX_DESCRIPTOR_HEAP_ALLOC_COUNT)
		}
	}
}

gfx_descriptor_fini :: proc "contextless" () {
	context = default_context()

	for &heap in gfx_descriptor.heaps {
		oa.destroy(&heap.heap)

		(heap.resource != nil) or_continue
		heap.resource->Release()
	}

}

gfx_descriptor_alloc :: proc(handle: ^$H/Gfx_Descriptor_Handle($T, $C)) -> bool {
	ok: bool
	when C == 1 {
		handle.slot, ok = sa.alloc(&gfx_descriptor.heaps[T].slots)
	} else {
		handle.allocation, ok = oa.allocate(&gfx_descriptor.heaps[T].heap, C)
	}
	return ok
}

gfx_descriptor_free :: proc(handle: $H/Gfx_Descriptor_Handle($T, $C)) {
	when C == 1 {
		sa.free(&gfx_descriptor.heaps[T].slots, handle.slot)
	} else {
		oa.free(&gfx_descriptor.heaps[T].heap, handle.allocation)
	}
}

gfx_descriptor_cpu :: proc(handle: $H/Gfx_Descriptor_Handle($T, $C), sub_index := 0, loc := #caller_location) -> d3d12.CPU_DESCRIPTOR_HANDLE {
	idx := gfx_descriptor_idx(handle, sub_index, loc)
	ok := true

	out := gfx_descriptor.heaps[T].start_cpu
	out.ptr += uint(idx) * uint(gfx_descriptor.heaps[T].inc)
	return out
}

gfx_descriptor_gpu :: proc(handle: $H/Gfx_Descriptor_Handle($T, $C), sub_index := 0, loc := #caller_location) -> d3d12.GPU_DESCRIPTOR_HANDLE {
	idx := gfx_descriptor_idx(handle, sub_index, loc)
	ok := true

	out := gfx_descriptor.heaps[T].start_gpu
	out.ptr += u64(idx) * u64(gfx_descriptor.heaps[T].inc)
	return out
}

gfx_descriptor_idx :: proc(handle: $H/Gfx_Descriptor_Handle($T, $C), sub_index := 0, loc := #caller_location) -> int {
	idx: int
	ok: bool

	when C == 1 {
		idx, ok = sa.get(&gfx_descriptor.heaps[T].slots, handle.slot)
	} else {
		// Let's say the heap comes after the slot array in memory.
		// Note it's an implementation detail that offset allocator indices are >0!!
		idx = int(GFX_DESCRIPTOR_SPECS[T].count_slots) + int(handle.allocation.offset)
		ok = handle.allocation.index > 0

		// Allow sub-indexing.
		log.assertf(sub_index < int(C), "cannot index past contiguously allocated heap range (%v < %v)", sub_index, C, loc = loc)
		idx += sub_index
	}

	// log.assertf(ok, "bad descriptor handle %v", handle, loc = loc)

	return idx
}
