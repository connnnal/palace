package superluminal

/*
BSD LICENSE

Copyright (c) 2019-2020 Superluminal. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:

  * Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.
  * Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in
    the documentation and/or other materials provided with the
    distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

ENABLED :: #config(USE_PERFORMANCEAPI_INSTRUMENTATION, false)

MAJOR_VERSION :: 3
MINOR_VERSION :: 0
VERSION :: (MAJOR_VERSION << 16) | MINOR_VERSION

/**
 * Helper struct that is used to prevent calls to EndEvent from being optimized to jmp instructions as part of tail call optimization.
 * You don't ever need to do anything with this as user of the API.
 */
SuppressTailCallOptimization :: struct {
	SuppressTailCall: [3]i64,
}

/**
 * Helper function to create an uint32_t color from 3 RGB values. The R, G and B values must be in range [0, 255].
 * The resulting color can be passed to the BeginEvent function.
 */
@(no_instrumentation)
MAKE_COLOR :: #force_inline proc(r, g, b: u8) -> u32 {
	return transmute(u32)[4]u8{0xFF, b, g, r}
}

/**
 * Use this define if you don't care about the color of an event and just want to use the default
 */
DEFAULT_COLOR :: u32(0xFFFFFFFF)

// TODO: We wrap foreign in a "when" because, even if unused, a lib missing on disk throws!
when ENABLED {
	foreign import lib "PerformanceAPI_MT.lib"
	@(private, default_calling_convention = "c", link_prefix = "PerformanceAPI_")
	foreign lib {
		/**
		 * Set the name of the current thread to the specified thread name. 
		 *
		 * @param inThreadName The thread name as an UTF8 encoded string.
		 */
		// SetCurrentThreadName :: proc "c" (inThreadName: cstring) ---

		/**
		 * Set the name of the current thread to the specified thread name. 
		 *
		 * @param inThreadName The thread name as an UTF8 encoded string.
		 * @param inThreadNameLength The length of the thread name, in characters, excluding the null terminator.
		 */
		SetCurrentThreadName_N :: proc(inThreadName: cstring, inThreadNameLength: u16) ---

		/**
		 * Begin an instrumentation event with the specified ID and runtime data
		 *
		 * @param inID    The ID of this scope as an UTF8 encoded string. The ID for a specific scope must be the same over the lifetime of the program (see docs at the top of this file)
		 * @param inData  [optional] The data for this scope as an UTF8 encoded string. The data can vary for each invocation of this scope and is intended to hold information that is only available at runtime. See docs at the top of this file.
		 *							 Set to null if not available.
		 * @param inColor [optional] The color for this scope. The color for a specific scope is coupled to the ID and must be the same over the lifetime of the program
		 *							 Set to PERFORMANCEAPI_DEFAULT_COLOR to use default coloring.
		 *
		 */
		// BeginEvent :: proc (inID: cstring, inData: cstring, inColor: u32) ---

		/**
		 * Begin an instrumentation event with the specified ID and runtime data, both with an explicit length.
	 
		 * It works the same as the regular BeginEvent function (see docs above). The difference is that it allows you to specify the length of both the ID and the data,
		 * which is useful for languages that do not have null-terminated strings.
		 *
		 * Note: both lengths should be specified in the number of characters, not bytes, excluding the null terminator.
		 */
		BeginEvent_N :: proc(inID: cstring, inIDLength: u16, inData: cstring, inDataLength: u16, inColor: u32) ---

		/**
		 * Begin an instrumentation event with the specified ID and runtime data
		 *
		 * @param inID    The ID of this scope as an UTF16 encoded string. The ID for a specific scope must be the same over the lifetime of the program (see docs at the top of this file)
		 * @param inData  [optional] The data for this scope as an UTF16 encoded string. The data can vary for each invocation of this scope and is intended to hold information that is only available at runtime. See docs at the top of this file.
		 						     Set to null if not available.
		 * @param inColor [optional] The color for this scope. The color for a specific scope is coupled to the ID and must be the same over the lifetime of the program
		 *							 Set to PERFORMANCEAPI_DEFAULT_COLOR to use default coloring.
		 */
		// BeginEvent_Wide :: proc (inID: [^]u16, inData: [^]u16, inColor: u32) ---

		/**
		 * Begin an instrumentation event with the specified ID and runtime data, both with an explicit length.
	 
		 * It works the same as the regular BeginEvent_Wide function (see docs above). The difference is that it allows you to specify the length of both the ID and the data,
		 * which is useful for languages that do not have null-terminated strings.
		 *
		 * Note: both lengths should be specified in the number of characters, not bytes, excluding the null terminator.
		 */
		BeginEvent_Wide_N :: proc(inID: [^]u16, inIDLength: u16, inData: [^]u16, inDataLength: u16, inColor: u32) ---

		/**
		 * End an instrumentation event. Must be matched with a call to BeginEvent within the same function
		 * Note: the return value can be ignored. It is only there to prevent calls to the function from being optimized to jmp instructions as part of tail call optimization.
		 */
		EndEvent :: proc() -> SuppressTailCallOptimization ---

		/**
		 * Call this function when a fiber starts running
		 *
		 * @param inFiberID    The currently running fiber
		 */
		RegisterFiber :: proc(inFiberID: u64) ---

		/**
		 * Call this function before a fiber ends
		 *
		 * @param inFiberID    The currently running fiber
		 */
		UnregisterFiber :: proc(inFiberID: u64) ---

		/**
		 * The call to the Windows SwitchFiber function should be surrounded by BeginFiberSwitch and EndFiberSwitch calls. For example:
		 * 
		 *		PerformanceAPI_BeginFiberSwitch(currentFiber, otherFiber);
		 *		SwitchToFiber(otherFiber);
		 *		PerformanceAPI_EndFiberSwitch(currentFiber);
		 *
		 * @param inCurrentFiberID    The currently running fiber
		 * @param inNewFiberID		  The fiber we're switching to
		 */
		BeginFiberSwitch :: proc(inCurrentFiberID: u64, inNewFiberID: u64) ---

		/**
		 * The call to the Windows SwitchFiber function should be surrounded by BeginFiberSwitch and EndFiberSwitch calls
		 * 	
		 *		PerformanceAPI_BeginFiberSwitch(currentFiber, otherFiber);
		 *		SwitchToFiber(otherFiber);
		 *		PerformanceAPI_EndFiberSwitch(currentFiber);
		 *
		 * @param inFiberID    The fiber that was running before the call to SwitchFiber (so, the same as inCurrentFiberID in the BeginFiberSwitch call)
		 */
		EndFiberSwitch :: proc(inFiberID: u64) ---
	}

	@(deferred_none = EndEvent)
	InstrumentationScope :: #force_inline proc "contextless" (id: string, data: string = {}, color: u32 = DEFAULT_COLOR) {
		BeginEvent_N(cast(cstring)raw_data(id), auto_cast len(id), cast(cstring)raw_data(data), auto_cast len(data), color)
	}

	SetCurrentThreadName :: #force_inline proc "contextless" (name: string) {
		SetCurrentThreadName_N(cast(cstring)raw_data(name), auto_cast len(name))
	}
} else {
	InstrumentationScope :: #force_inline proc "contextless" (id: string, data: string = {}, color: u32 = DEFAULT_COLOR) {
		// Stub.
	}
	SetCurrentThreadName :: #force_inline proc "contextless" (name: string) {
		// Stub.
	}
}
