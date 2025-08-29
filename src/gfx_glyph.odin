package main

import "base:runtime"
import "core:container/intrusive/list"
import "core:log"
import "core:math"
import "core:math/bits"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "vendor:stb/rect_pack"

import win "core:sys/windows"
import d2w "lib:odin_d2d_dwrite"
import "lib:superluminal"
import "vendor:directx/d3d12"

GLYPH_TEX_LENGTH :: 1024
GLYPH_UPLOAD_SIZE :: mem.Megabyte // Per backbuffer.
GLYPH_X_SLOPS :: 4
GLYPH_COLOR := superluminal.MAKE_COLOR(255, 150, 0)

// They're probably slow to create, consider creating at startup before they're required.
GLYPH_PAGE_PREWARM_COUNT :: 1

DWRITE_IDENTITY :: d2w.DWRITE_MATRIX{1, 0, 0, 1, 0, 0}

// TODO: Consider texture arrays.
Glyph_Page :: struct #no_copy {
	using node: list.Node,
	descriptor: d3d12.CPU_DESCRIPTOR_HANDLE,
	texture:    ^d3d12.IResource,
	srv:        Gfx_Descriptor_Handle(.CBV_SRV_UAV, 1),
	pack:       rect_pack.Context,
	// TODO: Double-check this working memory is sufficient.
	pack_nodes: [128]rect_pack.Node,
}

Glyph_Key :: struct {
	// This ptr must be consistent.
	// We rely on DWrite de-duplicating the returned FontFace object.
	face:    ^d2w.IDWriteFontFace3,
	size:    f32,
	index:   u16,
	x_shift: u16,
}

Glyph_Run_Draw :: struct {
	glyph: ^Glyph_Cached,
	pos:   [2]f32,
	color: [4]f32,
}

Glyph_Run_Pending :: struct {
	attach: ^Gfx_Attach,
	rects:  []Glyph_Run_Draw,
	depth:  u32,
}

Glyph_Cached :: struct {
	// It's possible a glyph is empty (i.e. the "space" character),
	// in which case we won't rasterize nor assign it a page.
	page:       Maybe(^Glyph_Page),
	x, y, w, h: int,
	off:        [2]int,
}

glyph_state: struct {
	allocator:  runtime.Allocator,
	arena:      virtual.Arena,
	pages:      list.List,
	page_count: u32,
	discovery:  map[Glyph_Key]^Glyph_Cached,
	pending:    [dynamic]Glyph_Key,
	upload:     ^d3d12.IResource,
	upload_map: ^[BUFFER_COUNT * GLYPH_UPLOAD_SIZE]byte,
	draws:      [dynamic]Glyph_Run_Pending,
}

@(private, init)
glyph_init :: proc "contextless" () {
	superluminal.InstrumentationScope("Glyph Init", color = GLYPH_COLOR)

	context = default_context()

	{
		err := virtual.arena_init_growing(&glyph_state.arena)
		log.ensuref(err == nil, "failed to init arena %q", err)
		glyph_state.allocator = virtual.arena_allocator(&glyph_state.arena)
	}

	glyph_state.discovery.allocator = glyph_state.allocator
	reserve(&glyph_state.discovery, 256)
	glyph_state.pending.allocator = glyph_state.allocator
	reserve(&glyph_state.pending, 256)
	glyph_state.draws.allocator = glyph_state.allocator
	reserve(&glyph_state.draws, 256)

	hr := gfx_state.device->CreateCommittedResource(
		&{Type = .UPLOAD},
		{.CREATE_NOT_ZEROED},
		&{Dimension = .BUFFER, Width = BUFFER_COUNT * GLYPH_UPLOAD_SIZE, Height = 1, DepthOrArraySize = 1, MipLevels = 1, SampleDesc = {1, 0}, Layout = .ROW_MAJOR},
		d3d12.RESOURCE_STATE_GENERIC_READ,
		nil,
		d3d12.IResource_UUID,
		(^rawptr)(&glyph_state.upload),
	)
	check(hr, "failed to create glyph upload buffer")

	hr = glyph_state.upload->Map(0, &{}, (^rawptr)(&glyph_state.upload_map))
	check(hr, "failed to map glyph upload buffer")

	for _ in 0 ..< GLYPH_PAGE_PREWARM_COUNT {
		glyph_page_new()
	}
}

@(private, fini)
glyph_fini :: proc "contextless" () {
	context = default_context()

	glyph_state.upload->Release()

	// This iterator supports deletion.
	it := list.iterator_head(glyph_state.pages, Glyph_Page, "node")
	for page in list.iterate_next(&it) {
		glyph_page_destroy(page)
	}
}

glyph_page_new :: proc() -> ^Glyph_Page {
	superluminal.InstrumentationScope("Glyph Page New", color = GLYPH_COLOR)

	count := glyph_state.page_count
	defer glyph_state.page_count += 1

	page := new(Glyph_Page, glyph_state.allocator)
	rect_pack.init_target(&page.pack, GLYPH_TEX_LENGTH, GLYPH_TEX_LENGTH, raw_data(&page.pack_nodes), len(page.pack_nodes))
	rect_pack.setup_allow_out_of_mem(&page.pack, true)
	defer list.push_back(&glyph_state.pages, page)

	{
		hr := gfx_state.device->CreateCommittedResource(
			&{Type = .DEFAULT},
			{.CREATE_NOT_ZEROED},
			&{
				Dimension = .TEXTURE2D,
				Width = GLYPH_TEX_LENGTH,
				Height = GLYPH_TEX_LENGTH,
				DepthOrArraySize = 1,
				MipLevels = 1,
				Format = .R8_UNORM,
				SampleDesc = {1, 0},
			},
			d3d12.RESOURCE_STATE_COMMON,
			nil,
			d3d12.IResource_UUID,
			(^rawptr)(&page.texture),
		)
		checkf(hr, "failed to create texture atlas (index %v)", count)
	}
	{
		gfx_descriptor_alloc(&page.srv)
		handle := gfx_descriptor_cpu(page.srv)

		gfx_state.device->CreateShaderResourceView(
			page.texture,
			&{
				Format = .R8_UNORM,
				ViewDimension = .TEXTURE2D,
				// Map all channels to read from red (including alpha).
				Shader4ComponentMapping = d3d12.ENCODE_SHADER_4_COMPONENT_MAPPING(0, 0, 0, 0),
				Texture2D = {MostDetailedMip = 0, MipLevels = 1},
			},
			handle,
		)
	}


	return page
}

glyph_page_destroy :: proc(page: ^Glyph_Page) {
	superluminal.InstrumentationScope("Glyph Page Destroy", color = GLYPH_COLOR)

	page.texture->Release()
	gfx_descriptor_free(page.srv)

	free(page, glyph_state.allocator)
}

glyph_pass_cook :: proc(cmd_list: ^d3d12.IGraphicsCommandList, #any_int buffer_idx: int) -> (processed: bool) {
	(len(glyph_state.pending) > 0) or_return
	defer clear(&glyph_state.pending)

	superluminal.InstrumentationScope("Glyph Pass Cook", color = GLYPH_COLOR)
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	context.allocator = context.temp_allocator

	Glyph_To_Pack :: struct {
		pack:     rect_pack.Rect,
		analysis: ^d2w.IDWriteGlyphRunAnalysis,
		bounds:   win.RECT,
		out:      ^Glyph_Cached,
	}

	filter_packed :: proc(existing: #soa[]Glyph_To_Pack, allocator := context.temp_allocator) -> #soa[]Glyph_To_Pack {
		count := 0
		for v in existing {
			count += v.pack.was_packed ? 1 : 0
		}
		out := make(#soa[]Glyph_To_Pack, count, allocator)
		count = 0
		#no_bounds_check for v in existing {
			(!v.pack.was_packed) or_continue
			out[count] = v
			count += 1
		}
		return out
	}
	to_pack := make(#soa[]Glyph_To_Pack, len(glyph_state.pending), context.temp_allocator)

	TEXTURE_TYPE :: d2w.DWRITE_TEXTURE_TYPE.DWRITE_TEXTURE_ALIASED_1x1
	ANTIALIAS_MODE :: d2w.DWRITE_TEXT_ANTIALIAS_MODE.GRAYSCALE
	BYTES_PER_PIXEL :: 1

	// The suggested render parameters can yield lower-quality rasterization.
	// Especially at lower font sizes, this can harm quality without improving legibility.
	// This actually matches 1:1 with Direct2D's behaviour.
	USE_DWRITE_HEURISTIC :: false

	hr: win.HRESULT

	for key, i in glyph_state.pending {
		defer key.face->Release()

		index := key.index
		run := d2w.DWRITE_GLYPH_RUN {
			fontFace     = key.face,
			fontEmSize   = key.size,
			glyphCount   = 1,
			glyphIndices = &index,
			glyphOffsets = &{f32(key.x_shift) / GLYPH_X_SLOPS, 0},
		}

		transform := DWRITE_IDENTITY
		rendering_mode: d2w.DWRITE_RENDERING_MODE1
		grid_fit_mode: d2w.DWRITE_GRID_FIT_MODE
		when USE_DWRITE_HEURISTIC {
			hr = key.face->GetRecommendedRenderingMode3(run.fontEmSize, 1, 1, &transform, false, .ANTIALIASED, .NATURAL, nil, &rendering_mode, &grid_fit_mode)
			check(hr, "failed to get recommended rendering mode")
		} else {
			// This is what the heuristic returns in most cases? See above comment.
			rendering_mode = .NATURAL_SYMMETRIC
			grid_fit_mode = .ENABLED
		}

		#no_bounds_check pending := &to_pack[i]
		pending.out = glyph_state.discovery[key] or_else log.panicf("no key for %q", key)

		hr = text_state.factory->CreateGlyphRunAnalysis2(&run, &transform, rendering_mode, .NATURAL, grid_fit_mode, ANTIALIAS_MODE, 0, 0, &pending.analysis)
		check(hr, "failed to create glyph run analysis")

		hr = pending.analysis->GetAlphaTextureBounds(TEXTURE_TYPE, &pending.bounds)
		check(hr, "failed to get alpha texture bounds")

		pending.pack.w = rect_pack.Coord(pending.bounds.right - pending.bounds.left)
		pending.pack.h = rect_pack.Coord(pending.bounds.bottom - pending.bounds.top)
	}

	// Retain our initial set of pending glyphs. We need to free all this DWrite stuff...
	all_ever_pending := to_pack
	defer for v in all_ever_pending {
		v.analysis->Release()
	}

	// Share a buffer between all glyphs to reduce memory allocations.
	buf: [][BYTES_PER_PIXEL]u8

	upload_offset := GLYPH_UPLOAD_SIZE * buffer_idx
	upload_limit := upload_offset + GLYPH_UPLOAD_SIZE

	it := list.iterator_head(glyph_state.pages, Glyph_Page, "node")
	for {
		// Try existing pages before creating new ones.
		page := list.iterate_next(&it) or_else glyph_page_new()

		all_packed := rect_pack.pack_rects(&page.pack, to_pack.pack, cast(i32)len(to_pack))
		any_packed := false

		for &v in to_pack {
			(v.pack.was_packed) or_continue

			// We don't need to rasterize zero-size glyphs.
			width := int(v.pack.w)
			height := int(v.pack.h)
			(width > 0 && height > 0) or_continue

			// Allocate sufficient space for storing our rasteriation result.
			if required := uint(width * height); required > len(buf) {
				delete(buf)
				// Align up to the next power of two.
				excess_reservation := 0x2 << cast(u32)bits.log2(required)
				buf = make([][BYTES_PER_PIXEL]u8, excess_reservation, context.temp_allocator)
			}

			buf_bytes := slice.to_bytes(buf)
			hr = v.analysis->CreateAlphaTexture(TEXTURE_TYPE, &v.bounds, raw_data(buf_bytes), cast(u32)len(buf_bytes))
			check(hr, "failed to create alpha texture")

			// TODO: We need a proper upload system, we can easily hit this per-frame limit!
			aligned_width := mem.align_forward_int(width, d3d12.TEXTURE_DATA_PITCH_ALIGNMENT)
			glyph_start := upload_offset
			glyph_end := glyph_start + int(height) * aligned_width
			log.assert(glyph_end <= upload_limit, "upload buffer exhausted")
			for r in 0 ..< height {
				mem.copy_non_overlapping(&glyph_state.upload_map[glyph_start + r * aligned_width], &buf[r * width], width)
			}
			upload_offset = glyph_end

			input_desc := d3d12.RESOURCE_DESC {
				Dimension        = .TEXTURE2D,
				Width            = u64(width),
				Height           = u32(height),
				DepthOrArraySize = 1,
				MipLevels        = 1,
				SampleDesc       = {1, 0},
				Format           = .R8_UNORM,
				Layout           = .ROW_MAJOR,
			}

			footprint: d3d12.PLACED_SUBRESOURCE_FOOTPRINT
			gfx_state.device->GetCopyableFootprints(&input_desc, 0, 1, u64(glyph_start), &footprint, nil, nil, nil)

			copy_src: d3d12.TEXTURE_COPY_LOCATION
			copy_src.pResource = glyph_state.upload
			copy_src.Type = .PLACED_FOOTPRINT
			copy_src.PlacedFootprint = footprint

			copy_dst: d3d12.TEXTURE_COPY_LOCATION
			copy_dst.pResource = page.texture
			copy_dst.Type = .SUBRESOURCE_INDEX
			copy_dst.SubresourceIndex = 0

			cmd_list->CopyTextureRegion(&copy_dst, u32(v.pack.x), u32(v.pack.y), 0, &copy_src, nil)

			// Save results.
			v.out^ = {page, int(v.pack.x), int(v.pack.y), int(v.pack.w), int(v.pack.h), {int(v.bounds.left), int(v.bounds.top)}}
		}

		// "1" means all rects were packed.
		(all_packed < 1) or_break

		// If the page is empty, then we're stuck!
		// We have at least one glyph that will never fit the atlas.
		if page.pack.num_nodes == 0 {
			log.warn("failed to pack glyphs")
			break
		}

		// Otherwise, filter what we just packed and continue.
		to_pack = filter_packed(to_pack)
	}

	return true
}

// TODO: This method is super slow! Lots of pointer chasing and descriptor handle checking.
glyph_draw :: proc() {
	superluminal.InstrumentationScope("Glyph Draw", color = GLYPH_COLOR)

	for v in glyph_state.draws {
		for rect in v.rects {
			page := rect.glyph.page.? or_continue

			gfx_attach_draw(
				v.attach,
				rect.pos + {f32(rect.glyph.off.x), f32(rect.glyph.off.y)},
				{f32(rect.glyph.w), f32(rect.glyph.h)},
				rect.color,
				{f32(rect.glyph.x), f32(rect.glyph.w), f32(rect.glyph.y), f32(rect.glyph.h)} / f32(GLYPH_TEX_LENGTH),
				texi = cast(u32)gfx_descriptor_idx(page.srv),
				depth = v.depth,
			)
		}
	}
}

glyph_end_frame :: proc() {
	defer clear(&glyph_state.draws)
}

Glyph_Draw_Meta :: struct {
	render: Render,
	color:  [4]f32,
}

@(private = "file", rodata)
glyph_renderer_vtable: d2w.IDWriteTextRenderer_VTable = {
	QueryInterface = proc "system" (this: ^win.IUnknown, riid: win.REFIID, ppvObject: ^rawptr) -> win.HRESULT {
		switch riid {
		case d2w.IDWriteTextRenderer_UUID, d2w.IDWritePixelSnapping_UUID, win.IUnknown_UUID:
			ppvObject^ = this
			this->AddRef()
			return win.S_OK
		case:
			ppvObject^ = nil
			return transmute(win.HRESULT)u32(win.E_NOINTERFACE)
		}
	},
	AddRef = proc "system" (this: ^win.IUnknown) -> win.ULONG {
		return 0
	},
	Release = proc "system" (this: ^win.IUnknown) -> win.ULONG {
		return 0
	},
	IsPixelSnappingDisabled = proc "system" (this: ^d2w.IDWritePixelSnapping, clientDrawingContext: rawptr, isDisabled: ^win.BOOL) -> win.HRESULT {
		// TODO: Are we supporting this?
		isDisabled^ = win.FALSE
		return win.S_OK
	},
	GetCurrentTransform = proc "system" (this: ^d2w.IDWritePixelSnapping, clientDrawingContext: rawptr, transform: ^d2w.DWRITE_MATRIX) -> win.HRESULT {
		transform^ = DWRITE_IDENTITY
		return win.S_OK
	},
	GetPixelsPerDip = proc "system" (this: ^d2w.IDWritePixelSnapping, clientDrawingContext: rawptr, pixelsPerDip: ^f32) -> win.HRESULT {
		// TODO: What is a DIP??
		pixelsPerDip^ = 1
		return win.S_OK
	},
	DrawGlyphRun = proc "system" (
		this: ^d2w.IDWriteTextRenderer,
		clientDrawingContext: rawptr,
		baselineOriginX: f32,
		baselineOriginY: f32,
		measuringMode: d2w.DWRITE_MEASURING_MODE,
		glyphRun: ^d2w.DWRITE_GLYPH_RUN,
		glyphRunDescription: ^d2w.DWRITE_GLYPH_RUN_DESCRIPTION,
		clientDrawingEffect: ^win.IUnknown,
	) -> win.HRESULT {
		context = default_context()

		clientDrawingContext := cast(^Glyph_Draw_Meta)clientDrawingContext
		render, color := expand_values(clientDrawingContext^)

		attach := render.attach

		face3: ^d2w.IDWriteFontFace3
		hr := glyphRun.fontFace->QueryInterface(d2w.IDWriteFontFace2_UUID, (^rawptr)(&face3))
		check(hr, "failed to upgrade fontface")
		defer face3->Release()

		glyph_count := int(glyphRun.glyphCount)

		pack := soa_zip(
			slice.from_ptr(glyphRun.glyphIndices, glyph_count),
			// TODO: This ptr can be nil if we have few glyphs!! :^(
			glyphRun.glyphOffsets != nil ? slice.from_ptr(glyphRun.glyphOffsets, glyph_count) : make([]d2w.DWRITE_GLYPH_OFFSET, glyph_count, context.temp_allocator),
			slice.from_ptr(glyphRun.glyphAdvances, glyph_count),
		)

		pending := Glyph_Run_Pending {
			attach = attach,
			rects  = make([]Glyph_Run_Draw, glyph_count, context.temp_allocator),
			// TODO: Use an actual value lol.
			depth  = max(u32),
		}
		defer append(&glyph_state.draws, pending)

		sum_advance: f32
		for pack, i in pack {
			index, offset, advance := expand_values(pack)
			defer sum_advance += advance

			base, frac := math.modf(baselineOriginX + sum_advance + offset.advanceOffset)
			shift_x := u16(0.5 + frac * GLYPH_X_SLOPS)

			key := Glyph_Key {
				face    = face3,
				index   = index,
				size    = glyphRun.fontEmSize,
				x_shift = shift_x,
			}

			_, value_ptr, just_inserted := map_entry(&glyph_state.discovery, key) or_else log.panicf("out of map memory on %q", key)
			defer pending.rects[i] = {value_ptr^, {base, baselineOriginY + offset.ascenderOffset}, color}

			if just_inserted {
				face3->AddRef()
				value_ptr^ = new(Glyph_Cached, glyph_state.allocator)
				append(&glyph_state.pending, key)
			}
		}

		return win.S_OK
	},
	DrawUnderline = proc "system" (
		this: ^d2w.IDWriteTextRenderer,
		clientDrawingContext: rawptr,
		baselineOriginX: f32,
		baselineOriginY: f32,
		underline: ^d2w.DWRITE_UNDERLINE,
		clientDrawingEffect: ^win.IUnknown,
	) -> win.HRESULT {
		return win.S_OK
	},
	DrawStrikethrough = proc "system" (
		this: ^d2w.IDWriteTextRenderer,
		clientDrawingContext: rawptr,
		baselineOriginX: f32,
		baselineOriginY: f32,
		strikethrough: ^d2w.DWRITE_STRIKETHROUGH,
		clientDrawingEffect: ^win.IUnknown,
	) -> win.HRESULT {
		return win.S_OK
	},
	DrawInlineObject = proc "system" (
		this: ^d2w.IDWriteTextRenderer,
		clientDrawingContext: rawptr,
		originX: f32,
		originY: f32,
		inlineObject: ^d2w.IDWriteInlineObject,
		isSideways: win.BOOL,
		isRightToLeft: win.BOOL,
		clientDrawingEffect: ^win.IUnknown,
	) -> win.HRESULT {
		return win.S_OK
	},
}

@(private)
glyph_renderer := d2w.IDWriteTextRenderer {
	vtable = &glyph_renderer_vtable,
}
