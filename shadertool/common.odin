package shadertool

import "base:runtime"
import "core:log"
import "core:os"

@(private)
init_context :: proc "contextless" (c: ^runtime.Context) {
	@(static, rodata)
	file_console_logger_data := log.File_Console_Logger_Data {
		file_handle = os.INVALID_HANDLE,
		ident       = "",
	}

	c^ = runtime.default_context()

	c.logger.procedure = log.console_logger_proc
	c.logger.data = &file_console_logger_data
	c.logger.lowest_level = .Debug
	c.logger.options = log.Default_Console_Logger_Opts
}

// TODO: Refactor when we gain the ability to modify the default context.
default_context :: proc "contextless" () -> (c: runtime.Context) {
	init_context(&c)
	return
}
