package superluminal

import "base:runtime"
import "core:dynlib"
import "core:fmt"

ENABLED :: #config(USE_PERFORMANCEAPI_INSTRUMENTATION, false)

when false {
	@(private)
	superluminal_state: struct {
		lib:             dynlib.Library,
		ok:              bool,
		using functions: Functions,
	}

	@(private, init, no_instrumentation)
	superluminal_init :: proc "contextless" () {
		context = runtime.default_context()
		superluminal_state.lib, superluminal_state.ok = LoadFrom("PerformanceAPI.dll", &superluminal_state.functions)
	}

	@(private, fini, no_instrumentation)
	superluminal_fini :: proc "contextless" () {
		context = runtime.default_context()
		superluminal_state.ok = false
		Free(superluminal_state.lib)
	}

	AUTO_PROFILE :: false
	when AUTO_PROFILE {
		@(instrumentation_enter, no_instrumentation)
		superluminal_enter :: proc "contextless" (proc_address, call_site_return_address: rawptr, loc: runtime.Source_Code_Location) {
			if superluminal_state.ok {
				superluminal_state.BeginEventN(cast(cstring)raw_data(loc.procedure), cast(u16)len(loc.procedure), nil, 0, MAKE_COLOR(100, 255, 40))
			}
		}

		@(instrumentation_exit, no_instrumentation)
		superluminal_exit :: proc "contextless" (proc_address, call_site_return_address: rawptr, loc: runtime.Source_Code_Location) {
			if superluminal_state.ok {
				superluminal_state.EndEvent()
			}
		}
	}
}

@(deferred_none = EndEvent, disabled = !ENABLED)
InstrumentationScope :: #force_inline proc "contextless" (id: string, data: string = {}, color: u32 = DEFAULT_COLOR) {
	BeginEvent_N(transmute(cstring)raw_data(id), auto_cast len(id), transmute(cstring)raw_data(data), auto_cast len(data), color)
}
