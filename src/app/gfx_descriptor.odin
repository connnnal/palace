package main

import "core:log"
import d3d12 "vendor:directx/d3d12"

import sa "src:slot_array"

Gfx_Descriptor_Heap :: struct {
	resource:  ^d3d12.IDescriptorHeap,
	start_cpu: d3d12.CPU_DESCRIPTOR_HANDLE,
	start_gpu: d3d12.GPU_DESCRIPTOR_HANDLE,
	inc:       u32,
}

Gfx_Descriptor_Bucket :: struct {
	// TODO: This is oversized for now!
	usage: sa.Slot_Array(512),
	// Owning heap (can be shared between buckets).
	heap:  ^Gfx_Descriptor_Heap,
}

Gfx_Descriptor_Bucket_Spec :: struct {
	backing:            d3d12.DESCRIPTOR_HEAP_TYPE,
	// Region within the heap this bucket allocates from.
	sub_start, sub_end: u32,
	// Width of each sub-allocation.
	sub_width:          u32,
}

@(rodata)
gfx_descriptor_regions: [Gfx_Descriptor_Bucket_Type]Gfx_Descriptor_Bucket_Spec = {
	.CBV_SRV_UAV       = {.CBV_SRV_UAV, 0, 512, 1},
	.CBV_SRV_UAV_MULTI = {.CBV_SRV_UAV, 512, 1024, 4},
	.RTV               = {.RTV, 0, 16, 1},
	.DSV               = {.DSV, 0, 16, 1},
}

// Backing memory must fit the regions listed above.
@(rodata)
gfx_descriptor_size: [d3d12.DESCRIPTOR_HEAP_TYPE]int = {
	.CBV_SRV_UAV = 1024,
	.SAMPLER     = 0,
	.RTV         = 16,
	.DSV         = 16,
}

gfx_descriptor: struct {
	heaps:   [d3d12.DESCRIPTOR_HEAP_TYPE]Gfx_Descriptor_Heap,
	buckets: [Gfx_Descriptor_Bucket_Type]Gfx_Descriptor_Bucket,
}

Gfx_Descriptor_Bucket_Type :: enum {
	CBV_SRV_UAV,
	CBV_SRV_UAV_MULTI,
	RTV,
	DSV,
}

Gfx_Descriptor_Handle :: struct {
	bucket:       Gfx_Descriptor_Bucket_Type,
	using handle: sa.Handle,
}

gfx_descriptor_init :: proc() {
	for &heap, type in gfx_descriptor.heaps {
		// Calculate requirement for backing the buckets.
		size: u32 = 0
		for region in gfx_descriptor_regions {
			(region.backing == type) or_continue
			size = max(size, region.sub_end)
		}

		// Some descriptor types may go unused.
		(size > 0) or_continue

		gpu_visible := type == .CBV_SRV_UAV

		hr := gfx_state.device->CreateDescriptorHeap(
			&{Type = type, NumDescriptors = size, Flags = gpu_visible ? {.SHADER_VISIBLE} : {}},
			d3d12.IDescriptorHeap_UUID,
			(^rawptr)(&heap.resource),
		)
		checkf(hr, "failed to create descriptor heap %q", type)

		heap.resource->GetCPUDescriptorHandleForHeapStart(&heap.start_cpu)
		if gpu_visible {
			heap.resource->GetGPUDescriptorHandleForHeapStart(&heap.start_gpu)
		}

		heap.inc = gfx_state.device->GetDescriptorHandleIncrementSize(type)
	}
}

gfx_descriptor_fini :: proc "contextless" () {
	for &heap, type in gfx_descriptor.heaps {
		(heap.resource != nil) or_continue
		heap.resource->Release()
	}
}

gfx_descriptor_alloc :: proc(type: Gfx_Descriptor_Bucket_Type) -> Gfx_Descriptor_Handle {
	bucket := &gfx_descriptor.buckets[type]
	spec := gfx_descriptor_regions[type]

	sa_handle := sa.alloc(&bucket.usage) or_else log.panicf("failed to allocate handle on bucket %v", type)
	log.assertf(sa_handle.idx * spec.sub_width < spec.sub_end - spec.sub_start, "failed to find free space on bucket %v", type)

	return {type, sa_handle}
}

gfx_descriptor_free :: proc(handle: Gfx_Descriptor_Handle) {
	sa.free(&gfx_descriptor.buckets[handle.bucket].usage, handle)
}

gfx_descriptor_cpu :: proc(handle: Gfx_Descriptor_Handle, #any_int child: u32 = 0) -> d3d12.CPU_DESCRIPTOR_HANDLE {
	type := handle.bucket
	spec := gfx_descriptor_regions[type]

	log.assertf(child < spec.sub_width, "child index %v specified on bucket %v with width %v", child, type, spec.sub_width)

	offset := (handle.idx + spec.sub_start) * gfx_descriptor.heaps[spec.backing].inc

	dhandle := gfx_descriptor.heaps[spec.backing].start_cpu
	dhandle.ptr += uint(handle.idx * spec.sub_width + spec.sub_start + child) * uint(gfx_descriptor.heaps[spec.backing].inc)

	return dhandle
}

gfx_descriptor_gpu :: proc(handle: Gfx_Descriptor_Handle, #any_int child: u32 = 0) -> d3d12.GPU_DESCRIPTOR_HANDLE {
	type := handle.bucket
	spec := gfx_descriptor_regions[type]

	log.assertf(child < spec.sub_width, "child index %v specified on bucket %v with width %v", child, type, spec.sub_width)

	offset := (handle.idx + spec.sub_start) * gfx_descriptor.heaps[spec.backing].inc

	dhandle := gfx_descriptor.heaps[spec.backing].start_gpu
	dhandle.ptr += u64(handle.idx * spec.sub_width + spec.sub_start + child) * u64(gfx_descriptor.heaps[spec.backing].inc)

	return dhandle
}
