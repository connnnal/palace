package main

import "base:intrinsics"
import "core:hash"
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

text_state: struct {
	factory:    ^d2w.IDWriteFactory5,
	loader:     ^d2w.IDWriteInMemoryFontFileLoader,
	collection: ^d2w.IDWriteFontCollection1,
	names:      [Text_Typeface]win.wstring,
}

@(init)
text_init :: proc "contextless" () {
	context = default_context()

	text_state.names = {
		.Body    = win.L("Epilogue"),
		.Special = win.L("Epilogue"),
	}

	hr := d2w.DWriteCreateFactory(.ISOLATED, d2w.IDWriteFactory5_UUID, (^rawptr)(&text_state.factory))
	check(hr, "failed to create dwrite factory")

	// Can we tell DWrite to ignore the system collection?
	// Checking it for the default(?) font causes a significant slowdown (~.1ms).
	// https://www.chromium.org/developers/design-documents/directwrite-font-proxy/.
	hr = text_state.factory->CreateInMemoryFontFileLoader(&text_state.loader)
	check(hr, "failed to create in memory font file loader")

	hr = text_state.factory->RegisterFontFileLoader(text_state.loader)
	check(hr, "failed to register font file loader")

	builder: ^d2w.IDWriteFontSetBuilder
	hr = text_state.factory->CreateFontSetBuilder(&builder)
	check(hr, "failed to create font set builder")
	defer builder->Release()

	for v in ([?]string{"Black", "Light", "SemiBold", "BlackItalic", "LightItalic", "SemiBoldItalic"}) {
		font: ^d2w.IDWriteFontFile

		// TODO: Tie this to some IUnknown to avoid memcpy.
		path := strings.join({`.\..\..\Downloads\Epilogue_Complete\Fonts\OTF\Epilogue-`, v, ".otf"}, "", context.temp_allocator)
		data := os2.read_entire_file_from_path(path, context.temp_allocator) or_continue
		hr = text_state.loader->CreateInMemoryFontFileReference(text_state.factory, raw_data(data), auto_cast len(data), nil, &font)
		check(hr, "failed to load font from memory")
		defer font->Release()

		reference: ^d2w.IDWriteFontFaceReference
		hr = text_state.factory->CreateFontFaceReference(font, 0, .NONE, &reference)
		check(hr, "failed to create font face reference")

		hr = builder->AddFontFaceReference1(reference)
		check(hr, "failed to create font face reference")
	}

	set: ^d2w.IDWriteFontSet
	hr = builder->CreateFontSet(&set)
	check(hr, "failed to create font set")
	defer set->Release()

	hr = text_state.factory->CreateFontCollectionFromFontSet(set, &text_state.collection)
	check(hr, "failed to create font face collection")
}

@(fini)
text_shutdown :: proc "contextless" () {
	text_state.loader->Release()
	text_state.factory->Release()
	text_state.collection->Release()
}

Text_Format_Props :: struct {
	typeface:    Text_Typeface,
	font_weight: d2w.DWRITE_FONT_WEIGHT,
	font_style:  d2w.DWRITE_FONT_STYLE,
	size:        i32,
}

Text_Layout_State :: struct {
	layout:        ^d2w.IDWriteTextLayout3,
	// For use with an imgui; this contents is valid only for the frame it's set on.
	// Therefore, this must be updated every frame.
	contents:      string,
	contents_hash: u64,
	// "This object may not be thread-safe, and it may carry the state of text format change."
	// https://learn.microsoft.com/en-us/windows/win32/api/dwrite/nn-dwrite-idwritetextformat#remarks.
	props:         Text_Format_Props,
	props_hash:    uintptr,
	format:        ^d2w.IDWriteTextFormat,
}

text_state_hydrate :: proc(state: ^Text_Layout_State, desc: Text_Desc) {
	state.props = Text_Format_Props {
		typeface    = desc.typeface,
		font_weight = desc.font_weight,
		font_style  = desc.font_style,
		size        = desc.size,
	}
	state.contents = desc.contents
}

text_state_cache :: proc(state: ^Text_Layout_State, available: [2]f32) -> (layout: ^d2w.IDWriteTextLayout3, ok: bool) #no_bounds_check {
	did_change_format: bool

	// Text format.
	{
		props := state.props
		hash := intrinsics.type_hasher_proc(Text_Format_Props)(&props, 0)

		invalid: bool
		existing := state.format != nil

		if state.props_hash != hash || !existing {
			defer state.props_hash = hash
			invalid = true
			did_change_format = true
		}

		if invalid && existing {
			state.format->Release()
		}
		if invalid {
			hr := text_state.factory->CreateTextFormat(
				text_state.names[props.typeface],
				text_state.collection,
				props.font_weight,
				.NORMAL,
				.NORMAL,
				f32(props.size),
				win.L("en-US"),
				&state.format,
			)
			checkf(hr, "failed to create text format (%v)", props)
		}
	}

	// Text layout.
	{
		available: [2]f32 = {f32(available[0]), f32(available[1])}
		hash := hash.fnv64a(transmute([]byte)state.contents)

		destroy, recreate: bool
		existing := state.layout != nil

		if state.contents_hash != hash || !existing || did_change_format {
			defer state.contents_hash = hash
			destroy = existing
			recreate = len(state.contents) > 0
		}

		if destroy {
			state.layout->Release()
			state.layout = nil
		}
		if recreate {
			str := win.utf8_to_utf16(state.contents, context.temp_allocator)

			// TODO: This throws with a size of zero.
			// TODO: Gracefully handle text layouting failures.
			temp: ^d2w.IDWriteTextLayout
			hr := text_state.factory->CreateTextLayout(raw_data(str), cast(u32)len(str), state.format, available[0], available[1], &temp)
			checkf(hr, "failed to create text layout (%v)", state.contents)
			defer temp->Release()

			hr = temp->QueryInterface(d2w.IDWriteTextLayout3_UUID, (^rawptr)(&state.layout))
			check(hr, "failed to upgrade interface")
		}
		if !recreate && !destroy && existing {
			// This is basically free, just always update this.
			state.layout->SetMaxWidth(available[0])
			state.layout->SetMaxHeight(available[1])
		}
	}

	return state.layout, true
}

// TODO: This could actually be stale, we should check the hash.
text_state_get_valid_layout :: proc(state: ^Text_Layout_State) -> (ptr: ^d2w.IDWriteTextLayout3, ok: bool) {
	return state.layout, state.layout != nil
}

text_state_destroy :: proc(state: ^Text_Layout_State) {
	if state.format != nil {
		state.format->Release()
	}
	if state.layout != nil {
		state.layout->Release()
	}
	state^ = {}
}
