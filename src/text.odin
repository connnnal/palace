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

text_state_hydrate :: proc(backing: ^Maybe(Text_Layout_State), desc: Maybe(Text_Desc)) {
	if desc, ok := desc.?; ok {
		value := backing.? or_else {}
		defer backing^ = value

		value.props = Text_Format_Props {
			typeface    = desc.typeface,
			font_weight = desc.font_weight,
			font_style  = desc.font_style,
			size        = desc.size,
		}
		value.contents = desc.contents
	} else {
		text_state_destroy(backing)
	}
}

text_state_cache :: proc(backing: ^Maybe(Text_Layout_State), available: [2]f32) -> ^d2w.IDWriteTextLayout3 #no_bounds_check {
	backing := &backing.? or_else panic("bad call")

	did_change_format: bool

	// Text format.
	{
		props := backing.props
		hash := intrinsics.type_hasher_proc(Text_Format_Props)(&props, 0)

		invalid: bool
		existing := backing.format != nil

		if backing.props_hash != hash || !existing {
			defer backing.props_hash = hash
			invalid = true
			did_change_format = true
		}

		if invalid && existing {
			backing.format->Release()
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
				&backing.format,
			)
			checkf(hr, "failed to create text format (%v)", props)
		}
	}

	// Text layout.
	{
		contents := backing.contents
		hash := hash.fnv64a(transmute([]byte)contents)

		invalid: bool
		existing := backing.layout != nil

		if backing.contents_hash != hash || !existing || did_change_format {
			defer backing.contents_hash = hash
			invalid = true
		}

		if invalid && existing {
			backing.layout->Release()
		}
		if invalid {
			str := win.utf8_to_utf16(contents, context.temp_allocator)

			// TODO: This throws with a size of zero.
			// TODO: Gracefully handle text layouting failures.
			temp: ^d2w.IDWriteTextLayout
			hr := text_state.factory->CreateTextLayout(raw_data(str), cast(u32)len(str), backing.format, f32(available[0]), f32(available[1]), &temp)
			checkf(hr, "failed to create text layout (%v)", backing.contents)
			defer temp->Release()

			hr = temp->QueryInterface(d2w.IDWriteTextLayout3_UUID, (^rawptr)(&backing.layout))
			check(hr, "failed to upgrade interface")
		} else {
			// This is basically free, just always update this.
			backing.layout->SetMaxWidth(f32(available[0]))
			backing.layout->SetMaxHeight(f32(available[1]))
		}
	}

	return backing.layout
}

// TODO: This could actually be stale, we should check the hash.
text_state_get_valid_layout :: proc(backing: ^Maybe(Text_Layout_State)) -> (ptr: ^d2w.IDWriteTextLayout3, ok: bool) {
	backing := backing.? or_return
	return backing.layout, backing.layout != nil
}

text_state_destroy :: proc(backing: ^Maybe(Text_Layout_State)) {
	if value, ok := &backing.?; ok {
		defer backing^ = nil
		if value.format != nil {
			value.format->Release()
		}
		if value.layout != nil {
			value.layout->Release()
		}
	}
}
