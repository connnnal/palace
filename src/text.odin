package main

import "base:intrinsics"
import "core:log"
import "core:os/os2"
import "core:strings"

import win "core:sys/windows"
import d2w "lib:odin_d2d_dwrite"

Text_Typeface :: enum {
	Body,
	Special,
}

Text_Desc :: struct {
	typeface:    Text_Typeface,
	font_weight: d2w.DWRITE_FONT_WEIGHT,
	font_style:  d2w.DWRITE_FONT_STYLE,
	size:        i32,
	contents:    string,
}

Text_Format_Key :: struct {
	typeface:    Text_Typeface,
	font_weight: d2w.DWRITE_FONT_WEIGHT,
	font_style:  d2w.DWRITE_FONT_STYLE,
	size:        i32,
}

#assert(len(d2w.DWRITE_FONT_WEIGHT) == 17)

Text_Measure_Key :: struct {
	available:    [2]Ly_Length,
	contents:     string,
	using format: Text_Format_Key,
}

Query_Format :: struct {}

text_state: struct {
	formats:    map[uintptr]^d2w.IDWriteTextFormat,
	layouts:    map[uintptr]^d2w.IDWriteTextLayout,
	factory:    ^d2w.IDWriteFactory5,
	loader:     ^d2w.IDWriteInMemoryFontFileLoader,
	set:        ^d2w.IDWriteFontSet,
	collection: ^d2w.IDWriteFontCollection1,
}

@(init)
text_init :: proc "contextless" () {
	context = default_context()

	hr := d2w.DWriteCreateFactory(.SHARED, d2w.IDWriteFactory5_UUID, (^rawptr)(&text_state.factory))
	check(hr, "failed to create dwrite factory")

	hr = text_state.factory->CreateInMemoryFontFileLoader(&text_state.loader)
	check(hr, "failed to create in memory font file loader")

	hr = text_state.factory->RegisterFontFileLoader(text_state.loader)
	check(hr, "failed to register font file loader")

	builder: ^d2w.IDWriteFontSetBuilder
	hr = text_state.factory->CreateFontSetBuilder(&builder)
	check(hr, "failed to create font set builder")
	defer builder->Release()

	for v in ([?]string{"Black", "Light", "SemiBold"}) {
		font: ^d2w.IDWriteFontFile

		path := strings.join({`.\..\..\Downloads\Epilogue_Complete\Fonts\OTF\Epilogue-`, v, ".otf"}, "", context.temp_allocator)
		data, err := os2.read_entire_file_from_path(path, context.temp_allocator)
		hr = text_state.loader->CreateInMemoryFontFileReference(text_state.factory, raw_data(data), auto_cast len(data), nil, &font)
		check(hr, "failed to load font from memory")
		defer font->Release()

		reference: ^d2w.IDWriteFontFaceReference
		hr = text_state.factory->CreateFontFaceReference(font, 0, .NONE, &reference)
		check(hr, "failed to create font face reference")

		hr = builder->AddFontFaceReference1(reference)
		check(hr, "failed to create font face reference")
	}

	hr = builder->CreateFontSet(&text_state.set)
	check(hr, "failed to create font set")

	hr = text_state.factory->CreateFontCollectionFromFontSet(text_state.set, &text_state.collection)
	check(hr, "failed to create font face collection")
}

@(fini)
text_shutdown :: proc "contextless" () {
	context = default_context()

	text_state.loader->Release()
	text_state.factory->Release()
	text_state.set->Release()
	text_state.collection->Release()

	delete(text_state.formats)
	delete(text_state.layouts)
}

Text_Cache_Format_Handle :: distinct uintptr

text_cache_format :: proc(key: Text_Format_Key) -> (^d2w.IDWriteTextFormat, Text_Cache_Format_Handle) {
	// TODO: Pick a seed, I guess..?
	key := key
	hash := intrinsics.type_hasher_proc(Text_Format_Key)(&key, 0)

	key_ptr, value_ptr, just_inserted := map_entry(&text_state.formats, hash) or_else log.panic("failed to allocate map space")

	if just_inserted {
		hr := text_state.factory->CreateTextFormat(
			win.L("Epilogue"),
			text_state.collection,
			key.font_weight,
			.NORMAL,
			.NORMAL,
			f32(key.size),
			win.L("en-US"),
			value_ptr,
		)
		checkf(hr, "failed to create text format (%v)", key)
	}

	return value_ptr^, Text_Cache_Format_Handle(hash)
}

Text_Cache_Measure_Handle :: distinct uintptr

text_cache_measure :: proc(key: Text_Measure_Key) -> (^d2w.IDWriteTextLayout, Text_Cache_Measure_Handle) {
	// TODO: Pick a seed, I guess..?
	key := key
	hash := intrinsics.type_hasher_proc(Text_Measure_Key)(&key, 0)

	key_ptr, value_ptr, just_inserted := map_entry(&text_state.layouts, hash) or_else log.panic("failed to allocate map space")

	if just_inserted {
		format, _ := text_cache_format(key)

		str := win.utf8_to_utf16(key.contents, context.temp_allocator)
		hr := text_state.factory->CreateTextLayout(
			raw_data(str),
			auto_cast len(str),
			format,
			f32(key.available[0].? or_else 99999),
			f32(key.available[1].? or_else 99999),
			value_ptr,
		)
		checkf(hr, "failed to create text layout (%v)", key)
	}

	return value_ptr^, Text_Cache_Measure_Handle(hash)
}
