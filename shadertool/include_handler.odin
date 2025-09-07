package shadertool

import "base:runtime"
import "core:log"
import "core:slice"
import "core:strings"
import win "core:sys/windows"
import "vendor:directx/dxc"

Include_Handler :: struct {
	using #subtype iincludehandler: dxc.IIncludeHandler,
	ctx:                   runtime.Context,
	allocator:             runtime.Allocator,
	utils:                 ^dxc.IUtils,
	referenced:            [dynamic]string,
}

include_handler_make :: proc(utils: ^dxc.IUtils, ctx := context, allocator := context.temp_allocator) -> Include_Handler {
	utils->AddRef()
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
	this.utils->Release()
	for k in this.referenced {
		delete(k, this.allocator)
	}
	delete(this.referenced)
}

include_handler_deps :: proc(this: Include_Handler, allocator := context.temp_allocator) -> []string {
	keys := make([]string, len(this.referenced), allocator) or_else log.panic("failed to allocate map keys")
	#no_bounds_check for &v, i in keys {
		v = strings.clone(this.referenced[i], allocator)
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

			filename = win.utf16_to_utf8_alloc(buf[:required - 1], context.temp_allocator) or_break seen_check
			seen_before = slice.contains(this.referenced[:], filename)
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
			// Need to clone filename off the temporary allocator.
			append(&this.referenced, strings.clone(filename, this.allocator))
		}

		return hr
	},
}
