package superluminal

import "core:dynlib"
import "core:fmt"

/**
 * Load the PerformanceAPI functions from the specified DLL path. If any part of this fails, the output 
 * outFunctions will be zero-initialized. 
 *
 * @param inPathToDLL	The path to the PerformanceAPI DLL. Note: The DLL at the specified path must match the architecture (i.e. x86 or x64) of the program this API is used in.
 * @param outFunctions	Pointer to a PerformanceAPI_Functions struct that will be filled with the correct function pointers to use the API. Filled with null pointers if the load failed for whatever reason.
 *
 * @return A handle to the module if the module was successfully loaded and the API retrieved; NULL otherwise. This can be used to free the module through PerformanceAPI_Free if needed.
 */
@(no_instrumentation)
LoadFrom :: proc(inPathToDll: string, outFunctions: ^Functions) -> (lib: dynlib.Library, ok: bool) {
	lib = dynlib.load_library(inPathToDll) or_return

	get_api := dynlib.symbol_address(lib, "PerformanceAPI_GetAPI") or_return
	get_api_fn := cast(GetAPI_Func)get_api

	code := get_api_fn(VERSION, outFunctions)
	ok = (code == 1)

	return
}

/**
 * Free the PerformanceAPI module that was previously loaded through PerformanceAPI_LoadFrom. After this function is called, you can no longer use the function pointers 
 * in the PerformanceAPI_Functions struct that you previously retrieved through PerformanceAPI_LoadFrom.
 *
 * @param inModule The module to free
 */
@(no_instrumentation)
Free :: proc(inModule: dynlib.Library) -> (ok: bool) {
	return dynlib.unload_library(inModule)
}
