// The filter memo.
//
// `check_filter` is the most expensive thing the app does and it runs on every keystroke in the
// filter box, so the result is cached against the normalised text. The python uses
// `functools.lru_cache(maxsize=256)` and measures an 87.6% hit rate under load; this is the same
// size and the same eviction policy.
//
// It is a plain map with a move-to-front list rather than a lock-guarded structure, because ONE
// SHARD owns each memo and runs every handler for it on one thread. That is the shared-nothing model
// paying out: the Go port needs a mutex here and the Rust port a `parking_lot` lock, and this needs
// neither.
//
// # One memo per shard, not one per system
//
// A `System` is shared by every shard -- it is loaded once, before `tina_start`, and never written.
// A memo is the opposite: it is written on every miss. So the memo cannot live on the `System`, and
// it does not: it lives in THREAD-LOCAL storage, indexed by `System.cache_slot`, and each shard
// builds its own on first use. The cost is one hit-rate warm-up and one map per system per shard;
// what it buys is that raising the shard count changes nothing here.
//
// # What the memo may allocate from
//
// `system.allocator` -- the corpus's own, which lives as long as the process -- and never the
// caller's. Inside a Tina handler `context.allocator` IS the per-call scratch arena, and a memo
// entry allocated there is dangling before the next request is served, while still being found by
// its key: a use-after-free that only shows up under enough concurrency to recycle the arena with
// different bytes. That is exactly what `render.active_topic_names` used to do.
package corpus

import "base:runtime"

FILTER_CACHE_SIZE :: 256

// How many systems one process can memoise for. The corpus has two.
MAX_SYSTEMS :: 8

// The memos this shard owns, one per system, built lazily on first use.
//
// `@(thread_local)` rather than a field on `System`, and rather than a lock: a Tina shard is an OS
// thread, so thread-local IS per-shard. Nothing here is ever touched by two threads.
@(private)
@(thread_local)
shard_caches: [MAX_SYSTEMS]Filter_Cache

@(private)
@(thread_local)
shard_caches_ready: [MAX_SYSTEMS]bool

// This shard's memo for `system`, made on first use.
//
// Lazily, because a shard cannot be reached before `tina_start` and the corpus is loaded before it:
// there is no boot moment on the shard's own thread to build these in. One map and one slot array
// per system per shard, once.
@(private)
shard_cache :: proc(system: ^System) -> ^Filter_Cache {
	slot := system.cache_slot
	assert(slot >= 0 && slot < MAX_SYSTEMS, "System.cache_slot out of range -- see corpus.load")
	if !shard_caches_ready[slot] {
		shard_caches[slot] = make_filter_cache(system.allocator)
		shard_caches_ready[slot] = true
	}
	return &shard_caches[slot]
}

// This shard's memo for `system`, for the debug panel and the tests.
filter_cache_for :: proc(system: ^System) -> ^Filter_Cache {
	return shard_cache(system)
}

@(private)
runtime_allocator :: runtime.Allocator

@(private)
Cache_Key :: struct {
	text:     string,
	min_hits: int,
}

@(private)
Cache_Entry :: struct {
	key:   Cache_Key,
	value: ^Filter_Check,
	// Recency, newest highest. A counter rather than a linked list: at 256 entries a linear scan
	// for the oldest costs less than maintaining the list, and it cannot get the order wrong.
	used:  u64,
}

Filter_Cache :: struct {
	entries: map[Cache_Key]int, // key -> slot in `slots`
	slots:   [dynamic]Cache_Entry,
	clock:   u64,
	hits:    int,
	misses:  int,
}

Cache_Info :: struct {
	hits, misses, size, max_size: int,
}

make_filter_cache :: proc(allocator := context.allocator) -> Filter_Cache {
	return Filter_Cache {
		entries = make(map[Cache_Key]int, FILTER_CACHE_SIZE, allocator),
		slots = make([dynamic]Cache_Entry, 0, FILTER_CACHE_SIZE, allocator),
	}
}

@(private)
cache_get :: proc(cache: ^Filter_Cache, text: string, min_hits: int) -> (check: ^Filter_Check, ok: bool) {
	slot, found := cache.entries[Cache_Key{text, min_hits}]
	if !found {
		cache.misses += 1
		return nil, false
	}
	cache.hits += 1
	cache.clock += 1
	cache.slots[slot].used = cache.clock
	return cache.slots[slot].value, true
}

@(private)
cache_put :: proc(
	cache: ^Filter_Cache,
	text: string,
	min_hits: int,
	check: ^Filter_Check,
	allocator: runtime_allocator,
) {
	// The caller's `text` is normalised into a scratch arena that is about to be reset, so the key
	// has to own its bytes.
	key := Cache_Key {
		text     = clone_string(text, allocator),
		min_hits = min_hits,
	}
	cache.clock += 1

	if len(cache.slots) < FILTER_CACHE_SIZE {
		append(&cache.slots, Cache_Entry{key = key, value = check, used = cache.clock})
		cache.entries[key] = len(cache.slots) - 1
		return
	}

	// Evict the least recently used. Its `Filter_Check` and hit list were allocated from the
	// system's own arena and are deliberately NOT freed: a request may still be holding the one
	// being evicted, and the arena is the process's lifetime anyway. What this bounds is the map,
	// not the memory -- which is the honest description of what the python's lru_cache does too.
	oldest := 0
	for entry, index in cache.slots {
		if entry.used < cache.slots[oldest].used {
			oldest = index
		}
	}
	delete_key(&cache.entries, cache.slots[oldest].key)
	cache.slots[oldest] = Cache_Entry {
		key   = key,
		value = check,
		used  = cache.clock,
	}
	cache.entries[key] = oldest
}

filter_cache_info :: proc(cache: Filter_Cache) -> Cache_Info {
	return Cache_Info{hits = cache.hits, misses = cache.misses, size = len(cache.slots), max_size = FILTER_CACHE_SIZE}
}

// Empty the memo. For tests and for a clean measurement window.
clear_filter_cache :: proc(cache: ^Filter_Cache) {
	clear(&cache.entries)
	clear(&cache.slots)
	cache.hits = 0
	cache.misses = 0
	cache.clock = 0
}

@(private = "file")
clone_string :: proc(text: string, allocator: runtime_allocator) -> string {
	if len(text) == 0 {
		return ""
	}
	buffer := make([]u8, len(text), allocator)
	copy(buffer, text)
	return string(buffer)
}
