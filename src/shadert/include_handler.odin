package shaders

import "base:runtime"
import "core:log"
import "core:slice"
import "core:strings"
import win "core:sys/windows"
import "vendor:directx/dxc"

Include_Handler :: struct {
	using iincludehandler: dxc.IIncludeHandler,
	ctx:                   runtime.Context,
	allocator:             runtime.Allocator,
	utils:                 ^dxc.IUtils,
	referenced:            map[string]struct {},
}

include_handler_make :: proc(utils: ^dxc.IUtils, ctx := context, allocator := context.temp_allocator) -> Include_Handler {
	this := Include_Handler {
		idxcincludehandler_vtable = &include_handler_vtable,
		utils                     = utils,
		allocator                 = allocator,
		ctx                       = ctx,
	}
	this.referenced.allocator = allocator
	return this
}

include_handler_destroy :: proc(this: Include_Handler) {
	for k in this.referenced {
		delete(k, this.allocator)
	}
	delete(this.referenced)
}

include_handler_deps :: proc(this: Include_Handler, allocator := context.temp_allocator) -> []string {
	keys := slice.map_keys(this.referenced, allocator) or_else log.panic("failed to allocate map keys")
	for &v in keys {
		v = strings.clone(v, allocator)
	}
	return keys
}

@(private = "file", rodata)
include_handler_vtable: dxc.IIncludeHandler_VTable = {
	QueryInterface = proc "system" (this: ^win.IUnknown, riid: win.REFIID, ppvObject: ^rawptr) -> win.HRESULT {
		switch riid {
		case win.IUnknown_UUID, dxc.IIncludeHandler_UUID:
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
	LoadSource = proc "system" (this: ^dxc.IIncludeHandler, pFilename: win.wstring, ppIncludeSource: ^^dxc.IBlob) -> win.HRESULT {
		// https://simoncoenen.com/blog/programming/graphics/DxcCompiling#custom-include-handler.
		this := cast(^Include_Handler)this

		context = this.ctx

		seen_before := false
		filename: string
		seen_check: {
			// Canonicalize so we can make comparisons.
			// I'm unsure under what conditions this fails. Perhaps if given a short path and the underlying file doesn't exist.
			// In that case, fall through and load the file regardless.
			required := win.GetFullPathNameW(pFilename, 0, nil, nil)
			buf := make([]u16, required, context.temp_allocator)
			ret := win.GetFullPathNameW(pFilename, required, cast(win.LPCWSTR)raw_data(buf), nil)
			(ret > 0) or_break seen_check

			err: runtime.Allocator_Error
			filename, err = win.utf16_to_utf8_alloc(buf[:required - 1], context.temp_allocator)
			(err == nil) or_break seen_check

			_, seen_before = this.referenced[filename]
		}

		hr: win.HRESULT
		blob_encoding: ^dxc.IBlobEncoding
		if seen_before {
			hr = this.utils->CreateBlobFromPinned(nil, 0, dxc.CP_ACP, &blob_encoding)
		} else {
			hr = this.utils->LoadFile(pFilename, nil, &blob_encoding)
		}

		ppIncludeSource^ = blob_encoding

		if !seen_before && win.SUCCEEDED(hr) {
			// Need to key string for permanent reference.
			this.referenced[strings.clone(filename, this.allocator)] = {}
		}

		return hr
	},
}
