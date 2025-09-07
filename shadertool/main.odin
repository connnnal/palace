package shadertool

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:hash/xxhash"
import "core:log"
import "core:mem/virtual"
import "core:os/os2"
import "core:reflect"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/info"
import "core:time"
import "core:unicode"
import "core:unicode/utf8"

import "lib:superluminal"

import win "core:sys/windows"
import tp "lib:threadpool"

import "vendor:directx/dxc"

FILE_BLOB :: "shaders.bin"
FILE_MANIFEST :: "shaders.odin"
FILE_HASH :: ".shader_log"
FILE_CONFIG :: "shaderconfig.sjson"

META_INLINE_LANE_TYPES :: true
META_WIDE_INTERVALS :: false

Compile_Work_Params :: struct {
	// Input.
	args:         ^dxc.ICompilerArgs,
	shader_name:  string,
	shader_path:  string,
	// Output.
	dependencies: []string,
	code:         []u8,
	ok:           bool,
}

work_queue: struct {
	allocator: runtime.Allocator,
	arena:     virtual.Arena,
	pool:      tp.PTP_POOL,
	cleaup:    tp.PTP_CLEANUP_GROUP,
	pending:   sync.Futex,
}

@(init)
work_init :: proc "contextless" () {
	context = default_context()

	// This allocator contains work input/output.
	if err := virtual.arena_init_growing(&work_queue.arena); err != nil {
		log.panicf("failed to init arena %q", err)
	}
	work_queue.allocator = virtual.arena_allocator(&work_queue.arena)

	// Left to its own devices, the threadpool will spam threads and create tons of contention.
	// We must set min/maxes.
	work_queue.pool = tp.CreateThreadpool(nil)
	{
		// Don't try to occupy all cores.
		count := cast(u32)max(info.cpu.logical_cores, info.cpu.physical_cores) - 2
		tp.SetThreadpoolThreadMaximum(work_queue.pool, count)
		tp.SetThreadpoolThreadMinimum(work_queue.pool, count)
	}

	work_queue.cleaup = tp.CreateThreadpoolCleanupGroup()
}

@(fini)
work_fini :: proc "contextless" () {
	context = default_context()

	work_flush()
	work_reset()

	tp.CloseThreadpoolCleanupGroup(work_queue.cleaup)
	virtual.arena_destroy(&work_queue.arena)

	tp.CloseThreadpool(work_queue.pool)
}

// Release resources after tasks are complete.
work_reset :: proc() {
	log.assertf(sync.atomic_load_explicit(&work_queue.pending, .Acquire) == 0, "all work should be completed")
	tp.CloseThreadpoolCleanupGroupMembers(work_queue.cleaup, win.FALSE, nil)
	virtual.arena_free_all(&work_queue.arena)
}

// Wait for queued tasks to finish.
work_flush :: proc() {
	for {
		value := sync.atomic_load_explicit(&work_queue.pending, .Acquire)
		(value > 0) or_break
		sync.futex_wait(&work_queue.pending, cast(u32)value)
	}
}

work_enqueue :: proc(params: ^Compile_Work_Params) {
	sync.atomic_add_explicit(&work_queue.pending, 1, .Relaxed)

	environ: tp.TP_CALLBACK_ENVIRON
	tp.InitializeThreadpoolEnvironment(&environ)
	tp.SetThreadpoolCallbackCleanupGroup(&environ, work_queue.cleaup, nil)
	tp.SetThreadpoolCallbackRunsLong(&environ)
	tp.SetThreadpoolCallbackRunsLong(&environ)
	tp.SetThreadpoolCallbackPool(&environ, work_queue.pool)

	// TODO: Creating work per task may be expensive; we can re-use work if we move the queue into our app.
	work_callback_wrapper :: proc "system" (instance: tp.PTP_CALLBACK_INSTANCE, parameter: win.PVOID, work: tp.PTP_WORK) {
		work_callback(cast(^Compile_Work_Params)parameter)

		// If we're the last task to finish, signal the waiter.
		remaining := sync.atomic_sub_explicit(&work_queue.pending, 1, .Relaxed)
		switch remaining {
		case 1:
			sync.futex_signal(&work_queue.pending)
		case 0:
			panic_contextless("job remaining underflow")
		}
	}
	work := tp.CreateThreadpoolWork(work_callback_wrapper, params, &environ)
	tp.SubmitThreadpoolWork(work)
}

// This runs on the threadpool!
work_callback :: proc "contextless" (params: ^Compile_Work_Params) {
	superluminal.InstrumentationScope("Compilation Callback", data = params.shader_name, color = superluminal.MAKE_COLOR(255, 100, 0))

	context = default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	start := time.tick_now()
	defer {
		end := time.tick_now()
		diff := time.tick_diff(start, end)
		if params.ok {
			log.infof("compiled %q in %v", params.shader_name, diff)
		} else {
			log.errorf("failed %q in %v", params.shader_name, diff)
		}
	}

	// TODO: Handle failing to read source file.
	shader_name := params.shader_name
	shader_source, _ := os2.read_entire_file(params.shader_path, context.temp_allocator)

	hr: win.HRESULT

	// "...all of the objects we provide aren't thread-safe. They're also not re-entrant except for AddRef/Release".
	// "...creating compiler instances is pretty cheap, so it's probably not worth the hassle of caching / sharing them".
	// https://github.com/Microsoft/DirectXShaderCompiler/issues/79.
	compiler: ^dxc.ICompiler3
	hr = dxc.CreateInstance(dxc.Compiler_CLSID, dxc.ICompiler3_UUID, (^rawptr)(&compiler))
	log.assert(win.SUCCEEDED(hr), "failed to create IDxcCompiler3")
	defer compiler->Release()

	utils: ^dxc.IUtils
	hr = dxc.CreateInstance(dxc.Utils_CLSID, dxc.IUtils_UUID, (^rawptr)(&utils))
	log.assert(win.SUCCEEDED(hr), "failed to create IDxcUtils")
	defer utils->Release()

	include_handler := include_handler_make(utils)
	defer include_handler_destroy(include_handler)

	result: ^dxc.IResult
	hr =
	compiler->Compile(
		&{raw_data(shader_source), len(shader_source), dxc.CP_UTF8},
		params.args->GetArguments(),
		params.args->GetCount(),
		&include_handler,
		dxc.IResult_UUID,
		&result,
	)
	log.assertf(win.SUCCEEDED(hr), "failed to invoke compilation for %q", shader_name)
	defer result->Release()

	// Release arguments, as discussed below.
	params.args->Release()

	// `.NONE` could mean the shader profile is mismatched!
	primary_output := result->PrimaryOutput()
	log.assertf(primary_output == .OBJECT, "unexpected output type for %q, got %q", shader_name, primary_output)

	// TODO: Upstream doesn't have these yet! https://github.com/odin-lang/Odin/pull/5591.
	when false {
		out_remarks: if result->HasOutput(.REMARKS) {
			out: ^dxc.IBlobUtf8
			hr = result->GetOutput(.REMARKS, dxc.IBlobUtf8_UUID, &out, nil)
			win.SUCCEEDED(hr) or_break out_remarks
			defer out->Release()

			out_slice := ([^]u8)(out->GetStringPointer())[:out->GetStringLength()]
			(len(out_slice) > 0) or_break out_remarks
			log.warnf("%q remarks: %s", shader_name, out_slice)
		}

		out_timing: if result->HasOutput(.TIME_REPORT) {
			out_blob: ^dxc.IBlob
			hr = result->GetOutput(.TIME_REPORT, dxc.IBlob_UUID, &out_blob, nil)
			win.SUCCEEDED(hr) or_break out_timing
			defer out_blob->Release()

			out_utf8: ^dxc.IBlobUtf8
			hr = utils->GetBlobAsUtf8(out_blob, &out_utf8)
			win.SUCCEEDED(hr) or_break out_timing
			defer out_utf8->Release()

			out_slice := ([^]u8)(out_utf8->GetStringPointer())[:out_utf8->GetStringLength()]
			(len(out_slice) > 0) or_break out_timing
			log.warnf("%q time report: %s", shader_name, out_slice)
		}
	}

	status: win.HRESULT
	hr = result->GetStatus(&status)
	log.assertf(win.SUCCEEDED(hr), "failed to query status for %q", shader_name)

	if win.SUCCEEDED(status) {
		out_blob: ^dxc.IBlob
		hr = result->GetResult(&out_blob)
		log.assertf(win.SUCCEEDED(hr), "failed to get result blob for %q", shader_name)
		defer out_blob->Release()

		out_slice := ([^]byte)(out_blob->GetBufferPointer())[:out_blob->GetBufferSize()]

		// Output on the work queue allocator so the calling thread can recieve this value.
		params.dependencies = include_handler_deps(include_handler, work_queue.allocator)
		params.code = slice.clone(out_slice, work_queue.allocator)
		params.ok = true
	} else {
		error_blob: ^dxc.IBlobEncoding
		hr = result->GetErrorBuffer(&error_blob)
		log.assertf(win.SUCCEEDED(hr), "failed to get error buffer for %q", shader_name)
		defer error_blob->Release()

		error_utf8: ^dxc.IBlobUtf8
		hr = utils->GetBlobAsUtf8(error_blob, &error_utf8)
		log.assertf(win.SUCCEEDED(hr), "failed to get error buffer as utf8 for %q", shader_name)
		defer error_utf8->Release()

		error_slice := ([^]u8)(error_utf8->GetStringPointer())[:error_utf8->GetStringLength()]
		error_trimmed := strings.trim_space(cast(string)error_slice)
		log.errorf("%q failed to compile: %s", shader_name, error_trimmed)
	}
}

// Bounded by work_queue allocator.
work_params_new :: proc(args: ^dxc.ICompilerArgs, shader_name: string, shader_path: string) -> ^Compile_Work_Params {
	params := new(Compile_Work_Params, work_queue.allocator)

	// The user-side work description is designed to be entirely freed when the allocator terminates.
	// This vestigial COM object can be freed after compilation, without affecting output.
	// This isn't unexpected behaviour as we aren't supposed to re-use work params.
	args->AddRef()
	params.args = args

	params.shader_name = strings.clone(shader_name, work_queue.allocator)
	params.shader_path = strings.clone(shader_path, work_queue.allocator)

	return params
}

Shader_Error :: enum {
	None,
	Compilation_Failed,
	Bad_Config,
}

Error :: union #shared_nil {
	Shader_Error,
	os2.Error,
}

main_ :: proc() -> Error {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	hr: win.HRESULT

	config := config_load(FILE_CONFIG) or_return

	if err := os2.make_directory_all(config.out_dir); err != nil {
		log.errorf("failed to ensure output path %q", config.out_dir)
		return err
	}

	utils: ^dxc.IUtils
	hr = dxc.CreateInstance(dxc.Utils_CLSID, dxc.IUtils_UUID, (^rawptr)(&utils))
	log.assert(win.SUCCEEDED(hr), "failed to create IDxcUtils")
	defer utils->Release()

	Shader_Computation_Combo :: struct {
		hash:  Hash,
		inner: union #no_nil {
			^Compile_Work_Params,
			[]byte,
		},
	}
	out_combos: [dynamic]Shader_Computation_Combo
	defer delete(out_combos)

	Shader_Computation :: struct {
		using shader:           Shader,
		combo_start, combo_end: int,
	}
	out_shaders: [dynamic]Shader_Computation
	defer delete(out_shaders)

	for shader in config.shaders {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

		out_shader: Shader_Computation
		out_shader.shader = shader
		out_shader.combo_start = len(out_combos)
		defer append(&out_shaders, out_shader)
		defer out_shader.combo_end = len(out_combos)

		// Compile against all combinations of the feature flag set.
		// Note that this includes empty.
		it := lane_iterator_make(shader.lanes, context.temp_allocator)
		defer lane_iterator_destroy(it)
		for combo in lane_iterator_next(&it) {
			shader_entry: Maybe(string)
			shader_source: Maybe(string) = shader.source
			shader_profile: Maybe(Profile)

			// Collect args.
			for v in combo {
				shader_entry = v.entry.? or_else (shader_entry.? or_else "")
				shader_source = v.source.? or_else (shader_source.? or_else "")
				shader_profile = v.profile.? or_else (shader_profile.? or_else nil)
			}
			if shader_entry == nil {
				log.warnf("failed to construct %q; missing shader_entry", shader.name)
				continue
			}
			if shader_source == nil {
				log.warnf("failed to construct %q; missing shader_source", shader.name)
				continue
			}
			if shader_profile == nil {
				log.warnf("failed to construct %q; missing shader_profile", shader.name)
				continue
			}
			shader_profile_name, shader_profile_name_ok := reflect.enum_name_from_value(shader_profile.(Profile))
			if !shader_profile_name_ok {
				log.warnf("failed to construct %q; bad shader_profile value %q", shader.name, shader_profile)
				continue
			}

			// Extend the source file's hash for this specific target.
			state: xxhash.XXH64_state
			xxhash.XXH64_reset_state(&state)
			xxhash.XXH64_update(&state, transmute([]byte)shader.name)
			maybe_hash_into(&state, shader_entry)
			maybe_hash_into(&state, shader_source)
			maybe_hash_into(&state, shader_profile)
			for tweak, i in combo {
				owning_lane := shader.lanes[i]
				xxhash.XXH64_update(&state, transmute([]byte)owning_lane.name)
				tweak_hash_into(&state, tweak)
			}
			hash := xxhash.XXH64_digest(&state)

			prev_output, prev_ok := d2_check(hash)

			out_combo: Shader_Computation_Combo
			out_combo.hash = hash
			out_combo.inner = prev_output
			defer append(&out_combos, out_combo)

			(!prev_ok) or_continue

			// Collect all defines from this tweak combination.
			defines: [dynamic]dxc.Define
			defines.allocator = context.temp_allocator
			for tweak in combo {
				inner_defines := kv_opts_into_dxc_defines(tweak.defines)
				append(&defines, ..inner_defines)
			}

			// Collect all compiler arguments from this tweak combination.
			arguments: [dynamic]win.wstring
			arguments.allocator = context.temp_allocator
			// append(&arguments, "-Qstrip_debug")
			// append(&arguments, "-Qstrip_reflect")
			// append(&arguments, "-Qstrip_priv")
			append(&arguments, "-ffinite-math-only")
			append(&arguments, "-Ges") // dxc.ARG_ENABLE_STRICTNESS
			append(&arguments, "-WX") // dxc.ARG_WARNINGS_ARE_ERRORS
			append(&arguments, "-pack-optimized")
			for tweak in combo {
				inner_arguments := kv_opts_into_dxc_args(tweak.args)
				append(&arguments, ..inner_arguments)
			}
			for dir in shader.include {
				append(&arguments, "-I", win.utf8_to_wstring(dir))
			}

			args: ^dxc.ICompilerArgs
			hr =
			utils->BuildArguments(
				win.utf8_to_wstring(shader_source.?),
				win.utf8_to_wstring(shader_entry.?),
				win.utf8_to_wstring(shader_profile_name),
				raw_data(arguments),
				cast(u32)len(arguments),
				raw_data(defines),
				cast(u32)len(defines),
				&args,
			)
			log.assertf(win.SUCCEEDED(hr), "failed to build arguments for %q", shader.name)
			defer args->Release()

			// Enqueue the work.
			params := work_params_new(args, shader.name, shader_source.?)
			work_enqueue(params)
			out_combo.inner = params

			// Output some debug info.
			debug_str: strings.Builder
			strings.builder_init(&debug_str, context.temp_allocator)
			{
				// Tweaks.
				fmt.sbprint(&debug_str, "\ttweak: ")
				for pack, i in soa_zip(combo, shader.lanes) {
					if i > 0 {
						fmt.sbprint(&debug_str, ", ")
					}
					fmt.sbprint(&debug_str, pack._0.name, pack._1.name, sep = "=")
				}
				fmt.sbprintln(&debug_str)

				// Arguments
				fmt.sbprint(&debug_str, "\targs: ")
				for arg_wstring, i in args->GetArguments()[:args->GetCount()] {
					if i > 0 {
						fmt.sbprint(&debug_str, ", ")
					}
					arg_string := win.wstring_to_utf8(arg_wstring, -1, context.temp_allocator) or_else "???"
					fmt.sbprint(&debug_str, arg_string)
				}
				fmt.sbprintln(&debug_str)
			}
			log.debugf("permute %s:\n%s", shader.name, strings.to_string(debug_str))
		}
	}

	// Wait on compilation tasks!
	work_flush()
	defer work_reset()

	// Manage work.
	all_ok := true
	for combo in out_combos {
		switch inner in combo.inner {
		case ^Compile_Work_Params:
			// If we just did some compilation, save that output.
			all_ok &&= inner.ok
			if inner.ok {
				// Need to add the actual source file as a dependency, too.
				// For the purposes of our caching we needn't separate "peers" from "inputs".
				dependencies := slice.concatenate([][]string{inner.dependencies, {inner.shader_path}}, context.temp_allocator)
				d2_record(combo.hash, dependencies, inner.code)
			}
		case []byte:
			// If it's compilation recovered from cache, mark it as up-to-date.
			d2_mark_relevant(combo.hash)
		}
	}

	if !all_ok {
		return .Compilation_Failed
	}

	// Concatenate into our output.
	{
		b := strings.builder_make(context.temp_allocator)
		defer strings.builder_destroy(&b)

		strings.write_string(&b, "package shader_meta")
		strings.write_string(&b, "\n\nimport \"vendor:directx/d3d12\"")
		strings.write_string(&b, "\n\n@(private) SOURCE_BLOB := #load(\"" + FILE_BLOB + "\")\n")

		out_bytes := 0
		for combo in out_combos {
			switch inner in combo.inner {
			case ^Compile_Work_Params:
				out_bytes += len(inner.code)
			case []byte:
				out_bytes += len(inner)
			}
		}

		buf := make([]byte, out_bytes, context.temp_allocator)
		defer delete(buf)

		out_offset := 0

		for shader in out_shaders {
			combos := out_combos[shader.combo_start:shader.combo_end]

			strings.write_string(&b, "\n")

			when META_INLINE_LANE_TYPES {
				fmt.sbprintfln(&b, "%s_Spec :: struct {{", strings.to_ada_case(shader.name))
				{
					for lane in shader.lanes {
						fmt.sbprintfln(&b, "\t%s: enum u8 {{", strings.to_snake_case(lane.name))
						for tweak in lane.tweaks {
							tweak_ident := tweak_identifier(tweak)
							// This ensures that the the identifier starts with an alphanumeric character.
							// Note that by definition this catches zero-width identifiers.
							if first := utf8.rune_at(tweak_ident, 0); !unicode.is_alpha(first) {
								tweak_ident = strings.concatenate({"_", tweak_ident}, context.temp_allocator)
							}
							if comment, comment_ok := tweak.comment.?; comment_ok {
								comment = strings.trim_space(comment)
								fmt.sbprintfln(&b, "\t\t%s, // %s", strings.to_ada_case(tweak_ident), comment)
							} else {
								fmt.sbprintfln(&b, "\t\t%s,", strings.to_ada_case(tweak_ident))
							}
						}
						fmt.sbprintln(&b, "\t},")
					}
				}
				fmt.sbprintln(&b, "}")
			} else {
				fmt.sbprintfln(&b, "%s_Spec :: struct {{", strings.to_ada_case(shader.name))
				{
					for lane in shader.lanes {
						fmt.sbprintfln(&b, "\t%s: %s_Opt_%s,", strings.to_snake_case(lane.name), strings.to_ada_case(shader.name), strings.to_ada_case(lane.name))
					}
				}
				fmt.sbprintln(&b, "}")

				for lane in shader.lanes {
					fmt.sbprintfln(&b, "%s_Opt_%s: enum u8 {{", strings.to_ada_case(shader.name), strings.to_ada_case(lane.name))
					for tweak in lane.tweaks {
						tweak_ident := tweak_identifier(tweak)
						// This ensures that the the identifier starts with an alphanumeric character.
						// Note that by definition this catches zero-width identifiers.
						if first := utf8.rune_at(tweak_ident, 0); !unicode.is_alpha(first) {
							tweak_ident = strings.concatenate({"_", tweak_ident}, context.temp_allocator)
						}
						if comment, comment_ok := tweak.comment.?; comment_ok {
							comment = strings.trim_space(comment)
							fmt.sbprintfln(&b, "\t%s, // %s", strings.to_ada_case(tweak_ident), comment)
						} else {
							fmt.sbprintfln(&b, "\t%s,", strings.to_ada_case(tweak_ident))
						}
					}
					fmt.sbprintln(&b, "}")
				}
			}

			fmt.sbprintfln(&b, "%s_Key :: distinct int", strings.to_ada_case(shader.name))
			fmt.sbprintfln(&b, "%s_KEY_CAP :: %i", strings.to_screaming_snake_case(shader.name), len(combos))
			fmt.sbprintfln(
				&b,
				"%s_key :: proc(spec: %s_Spec) -> %s_Key {{",
				strings.to_snake_case(shader.name),
				strings.to_ada_case(shader.name),
				strings.to_ada_case(shader.name),
			)
			{
				prev_mul := 1
				fmt.sbprint(&b, "\tkey := 0")
				for lane in shader.lanes {
					fmt.sbprintf(&b, " + int(spec.%s) * %i", strings.to_snake_case(lane.name), prev_mul)
					prev_mul *= len(lane.tweaks)
				}
				fmt.sbprintln(&b)
				fmt.sbprintfln(&b, "\treturn cast(%s_Key)key", strings.to_ada_case(shader.name))
			}
			fmt.sbprintln(&b, "}")

			fmt.sbprintfln(&b, "%s :: proc(spec: %s_Spec) -> d3d12.SHADER_BYTECODE {{", strings.to_snake_case(shader.name), strings.to_ada_case(shader.name))
			fmt.sbprintfln(&b, "\tidx := cast(int)%s_key(spec)", strings.to_snake_case(shader.name))
			when META_WIDE_INTERVALS {
				fmt.sbprintln(&b, "\t@(static, rodata) inner := [?][2]int{")
				for combo in combos {
					combo_len := 0
					switch inner in combo.inner {
					case ^Compile_Work_Params:
						combo_len = len(inner.code)
						copy(buf[out_offset:], inner.code)
					case []byte:
						combo_len = len(inner)
						copy(buf[out_offset:], inner)
					}
					fmt.sbprintfln(&b, "\t\t{{ %i, %i },", out_offset, out_offset + combo_len)
					out_offset += combo_len
				}
				fmt.sbprintln(&b, "\t}")
			} else {
				fmt.sbprint(&b, "\t@(static, rodata) inner := [?]int{")
				for combo in combos {
					combo_len := 0
					switch inner in combo.inner {
					case ^Compile_Work_Params:
						combo_len = len(inner.code)
						copy(buf[out_offset:combo_len + out_offset], inner.code)
					case []byte:
						combo_len = len(inner)
						copy(buf[out_offset:combo_len + out_offset], inner)
					}
					fmt.sbprintf(&b, "%i, ", out_offset)
					out_offset += combo_len
				}
				fmt.sbprintfln(&b, "%i}", out_offset)
			}
			fmt.sbprintln(&b, "\t#no_bounds_check slice := SOURCE_BLOB[inner[idx + 0]:inner[idx + 1]]")
			fmt.sbprintln(&b, "\treturn {raw_data(slice), len(slice)}")
			fmt.sbprintln(&b, "}")
		}

		{
			out_path := os2.join_path({config.out_dir, FILE_MANIFEST}, context.temp_allocator) or_return
			os2.write_entire_file(out_path, b.buf[:]) or_return
		}
		{
			out_path := os2.join_path({config.out_dir, FILE_BLOB}, context.temp_allocator) or_return
			os2.write_entire_file(out_path, buf[:]) or_return
		}
	}

	return nil
}

main :: proc() {
	context = default_context()

	// Exit with a non-zero code so subsequent steps don't run.
	if main_() != nil {
		runtime._cleanup_runtime()
		os2.exit(1)
	}
}
