package shadertool

import "base:intrinsics"
import "base:runtime"
import "core:encoding/json"
import "core:hash/xxhash"
import "core:log"
import "core:os/os2"
import "core:slice"
import "core:strings"

import win "core:sys/windows"
import "vendor:directx/dxc"

Config :: struct {
	out_dir: string,
	shaders: []Shader,
}

Shader :: struct {
	name:    string,
	source:  Maybe(string),
	include: []string,
	lanes:   []Lane,
}

Profile :: enum {
	rootsig_1_1,
	vs_6_6,
	ps_6_6,
	cs_6_6,
	cs_6_2,
}

Lane :: struct {
	// Label over this tweak group. Visible within the meta file.
	name:   string,
	// One tweak from this set will always be active.
	tweaks: []Tweak,
}

Kv_Opts :: union #no_nil {
	// Dictionary keys, values assumed to be empty strings.
	[]string,
	// Dictionary.
	map[string]string,
}

Tweak :: struct {
	// Label visible within the meta file.
	name:    string,
	// Additional compiler arguments.
	args:    Kv_Opts,
	// Documentation.
	comment: Maybe(string),
	// Preprocessor defines.
	defines: Kv_Opts,
	// Override the shader profile?
	profile: Maybe(Profile),
	// Override the shader entry?
	entry:   Maybe(string),
	// Override the shader source file?
	source:  Maybe(string),
}

kv_opts_count :: proc(opts: Kv_Opts) -> int {
	switch inner in opts {
	case []string:
		return len(inner)
	case map[string]string:
		return len(inner)
	}
	unreachable()
}

kv_opts_into_dxc_args :: proc(opts: Kv_Opts, allocator := context.temp_allocator) -> (out: []dxc.wstring) {
	switch inner in opts {
	case []string:
		count := len(inner)
		out = make([]dxc.wstring, count, allocator)
		for v, i in inner {
			log.ensuref(strings.starts_with(v, "-"), "bad arg key %q", v)
			out[i] = win.utf8_to_wstring(v, allocator)
		}
	case map[string]string:
		count := len(inner)
		out = make([]dxc.wstring, count * 2, allocator)
		i := 0
		for k, v in inner {
			defer i += 2
			log.ensuref(strings.starts_with(k, "-"), "bad arg key %q", k)
			out[i + 0] = win.utf8_to_wstring(k, allocator)
			out[i + 1] = win.utf8_to_wstring(v, allocator)
		}
	}
	return out
}

kv_opts_into_dxc_defines :: proc(opts: Kv_Opts, allocator := context.temp_allocator) -> (out: []dxc.Define) {
	switch inner in opts {
	case []string:
		count := len(inner)
		out = make([]dxc.Define, count, allocator)
		for k, i in inner {
			out[i].Name = win.utf8_to_wstring(k, allocator)
		}
	case map[string]string:
		count := len(inner)
		out = make([]dxc.Define, count, allocator)
		i := 0
		for k, v in inner {
			out[i].Name = win.utf8_to_wstring(k, allocator)
			out[i].Value = win.utf8_to_wstring(v, allocator)
			i += 1
		}
	}
	return out
}

kv_opts_hash_into :: proc(state: ^xxhash.XXH64_state, opts: Kv_Opts) {
	switch inner in opts {
	case []string:
		for v in inner {
			xxhash.XXH64_update(state, transmute([]byte)v)
		}
	case map[string]string:
		// To get deterministic hashing from the map, we must sort the keys!
		// I wish we could ask for a JSON map unpacked as an array in-order.
		{
			span := slice.map_keys(inner, context.temp_allocator) or_else log.panic("failed to allocate map slice")
			slice.sort(span)
			kv_opts_hash_into(state, span)
		}
		{
			span := slice.map_values(inner, context.temp_allocator) or_else log.panic("failed to allocate map slice")
			slice.sort(span)
			kv_opts_hash_into(state, span)
		}
	}
}

maybe_hash_into :: proc(state: ^xxhash.XXH64_state, value: Maybe($T)) {
	if inner, ok := value.?; ok {
		bytes: []u8
		when T == string {
			bytes = transmute([]byte)inner
		} else when intrinsics.type_is_slice(T) {
			bytes = slice.to_bytes(inner)
		} else {
			bytes = slice.bytes_from_ptr(&inner, size_of(T))
		}
		xxhash.XXH64_update(state, bytes)
	} else {
		// Fill with garbage, such that we mutate for a nil/zero-length value.
		bytes: [size_of(T)]u8 = ~u8(0)
		xxhash.XXH64_update(state, bytes[:])
	}
}

tweak_hash_into :: proc(state: ^xxhash.XXH64_state, tweak: Tweak) {
	xxhash.XXH64_update(state, transmute([]byte)tweak.name)
	kv_opts_hash_into(state, tweak.args)
	kv_opts_hash_into(state, tweak.defines)
	maybe_hash_into(state, tweak.profile)
	maybe_hash_into(state, tweak.entry)
	maybe_hash_into(state, tweak.source)
}

tweak_identifier :: proc(tweak: Tweak) -> string {
	return tweak.name
}

config_load :: proc(filename: string, allocator := context.temp_allocator) -> (Config, Error) {
	config_source, read_err := os2.read_entire_file(filename, allocator)
	if read_err != nil {
		log.errorf("failed to read %q: %v", filename, read_err)
		return {}, read_err
	}

	config: Config
	if err := json.unmarshal(config_source, &config, .SJSON, allocator); err != nil {
		log.errorf("failed to unmarshal %q: %v", filename, err)
		return {}, .Bad_Config
	}

	return config, nil
}

// To allows shaders with one (no?) variants without special consideration,
// the iterator yields at least once, even on an empty set of lanes.
// This does not extend the lanes' lifetime.
Lane_Iterator :: struct {
	allocator: runtime.Allocator,
	lanes:     []Lane,
	idx, cap:  int,
	set:       []Tweak,
}

lane_iterator_make :: proc(lanes: []Lane, allocator := context.temp_allocator) -> (it: Lane_Iterator) {
	it.cap = 1
	for lane in lanes {
		it.cap *= len(lane.tweaks)
	}
	it.set = make([]Tweak, len(lanes), allocator)
	it.lanes = lanes
	it.allocator = allocator
	return
}

lane_iterator_destroy :: proc(it: Lane_Iterator) {
	delete(it.set, it.allocator)
}

lane_iterator_next :: proc(it: ^Lane_Iterator) -> (combo: []Tweak, ok: bool) {
	(it.idx < it.cap) or_return
	defer it.idx += 1

	idx := it.idx
	for lane, i in it.lanes {
		tweaks := lane.tweaks
		it.set[i] = tweaks[idx % len(tweaks)]
		idx /= len(tweaks)
	}

	return it.set, true
}
