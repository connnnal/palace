package shadertool

import "base:runtime"
import "core:encoding/cbor"
import "core:hash/xxhash"
import "core:log"
import "core:mem/virtual"
import "core:os/os2"
import "core:slice"
import "core:strings"

// Similar naming convention to Ninja.
HASH_FILE :: ".hash_log"

Hash :: xxhash.XXH64_hash
Path :: string

Generation :: u64

D2_Item :: struct {
	generation: Generation,
	deps_hash:  Hash,
	deps:       []Path,
	// This always contains valid data.
	output:     []byte,
}

D2_Sz :: struct {
	exe_fingerprint: u64,
	generation:      Generation,
	items:           map[Hash]D2_Item,
}

d2_state: struct {
	allocator:  runtime.Allocator,
	arena:      virtual.Arena,
	using sz:   D2_Sz,
	stat_cache: map[string]os2.File_Info,
}

@(init)
d2_init :: proc "contextless" () {
	context = default_context()

	if err := virtual.arena_init_growing(&d2_state.arena); err != nil {
		log.panicf("failed to init arena %q", err)
	}
	d2_state.allocator = virtual.arena_allocator(&d2_state.arena)
	context.allocator = d2_state.allocator

	// The unmarshal impl borrows from its input, we can't use a temporary allocator.
	contents, read_err := os2.read_entire_file(HASH_FILE, context.allocator)
	if read_err != nil && read_err != .Not_Exist {
		log.warnf("failed to read log %q", HASH_FILE)
	}

	cbor_err := cbor.unmarshal(contents, &d2_state.sz, {.Trusted_Input})
	if cbor_err != nil && cbor_err != .Unexpected_EOF {
		log.warn("failed to unmarshal log", cbor_err)
	}
}

@(fini)
d2_fini :: proc "contextless" () {
	context = default_context()
	defer virtual.arena_destroy(&d2_state.arena)

	// Prune old entries.
	// We could choose to use a grace period of multiple generations, as a sort of undo cache.
	for k, v in d2_state.items {
		if d2_state.generation - v.generation > 0 {
			delete_key(&d2_state.items, k)
		}
	}
	d2_state.generation += 1
	d2_state.exe_fingerprint = ODIN_COMPILE_TIMESTAMP

	contents, cbor_err := cbor.marshal(d2_state.sz, allocator = context.temp_allocator)
	if cbor_err != nil {
		log.error("failed to marshal log")
	}

	write_err := os2.write_entire_file(HASH_FILE, contents)
	if write_err != nil {
		log.errorf("failed to write log %q", HASH_FILE)
	}
}

d2_record :: proc(hash: Hash, deps: []Path, output: []byte) {
	context.allocator = d2_state.allocator

	item: D2_Item
	item.generation = d2_state.generation
	item.output = slice.clone(output)

	// Clone paths onto the allocator for safe keeping :).
	// Order undetermined due to potential hashmap usage upstream, so sort.
	item.deps = slice.clone(deps)
	slice.sort(item.deps)
	for &v in item.deps {
		v = strings.clone(v)
	}

	// Compute hash for files as first seen.
	state: xxhash.XXH64_state
	for v in item.deps {
		d2_hash_into(&state, v)
	}
	item.deps_hash = xxhash.XXH64_digest(&state)

	d2_state.items[hash] = item
}

d2_check :: proc(hash: Hash) -> (output: []byte, did_exist: bool, deps_ok: bool) {
	item: D2_Item
	item, did_exist = d2_state.items[hash]

	state: xxhash.XXH64_state
	for v in item.deps {
		d2_hash_into(&state, v)
	}
	deps_ok = item.deps_hash == xxhash.XXH64_digest(&state)

	output = item.output

	return
}

d2_mark_relevant :: proc(hash: Hash) {
	item := &d2_state.items[hash] or_else log.panicf("no previous entry at hash %q", hash)
	item.generation = d2_state.generation
}

d2_hash_into :: proc(state: ^xxhash.XXH64_state, path: Path) -> bool {
	context.allocator = d2_state.allocator

	// Amortize stat calls, this will get really expensive across all shader combinations.
	key_ptr, value_ptr, just_inserted := map_entry(&d2_state.stat_cache, path) or_else log.panic("failed to insert into map")
	err: os2.Error

	if just_inserted {
		value_ptr^, err = os2.stat(path, d2_state.allocator)
		key_ptr^ = strings.clone(path)
	}

	if err != nil {
		log.warnf("failed to get stat for %q: %s", path, err)
	}

	xxhash.XXH64_update(state, transmute([]byte)value_ptr.fullpath)
	xxhash.XXH64_update(state, slice.bytes_from_ptr(&value_ptr.modification_time, size_of(value_ptr.modification_time)))

	return err == nil
}
