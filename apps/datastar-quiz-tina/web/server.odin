// The HTTP surface of the quiz: configuration, the route table, and boot.
//
// Everything here is Tina-shaped, and two of its constraints drive the whole design:
//
//   - A response is staged in a per-connection egress buffer whose size is fixed at COMPILE time
//     (`HTTP_EGRESS_BUFFER_SIZE`, see the justfile). `http.respond_bytes` does not stream: it stages
//     a 500 if body + headers do not fit. Anything larger than the buffer -- the index document,
//     every stylesheet, the datastar bundle -- goes out through an event route that calls
//     `begin_fixed_stream` and then writes on each `Send_Ready`.
//   - The Datastar SDK serialises each SSE event into ONE exact reservation in that same buffer, so
//     a single `patch_elements` is capped by it too. The fat morph is the reason the buffer is set
//     near the u16 ceiling rather than left at its 4096 default.
//
// The app-wide state below is package-level rather than threaded through the handlers, because Tina
// route handlers take no user pointer -- the framework owns the isolate that calls them. All of it
// is written during boot, BEFORE `tina_start` brings any shard up.
package web

import "../corpus"
import "../render"
import "../session"
import "../sfx"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import tina "tina:src"
import http "tina:src/extensions/http/server"

// Port 5061. The python serves 5008 and the Go port 5060, and all three are driven by the same
// `apps/dsquiz-perf` harness, so they need to run side by side.
DEFAULT_PORT :: 5061

// Connection slots are pre-allocated isolates, not a soft limit -- this many connections can exist
// and the rest are shed. It also multiplies the egress buffer: 512 × 63 KB is ~32 MB reserved at
// boot, before a single request arrives. That is the trade Tina asks for, and it belongs in
// RESULTS.md rather than hidden.
DEFAULT_CONNECTION_SLOTS :: 512

// One shard by default, and it is the number the comparison is measured at: the python's single
// asyncio loop and `just dsgo serve-1core` are the like-for-like budget. `DSQUIZ_SHARDS` raises it.
//
// The store no longer stands in the way of that -- it is an isolate now, reached by message, so a
// session is owned by one shard and reachable from all of them (`session/isolate.odin`). What does
// stand in the way is the platform: see `MAX_SHARDS` and the note in `shard_count_from_environment`.
DEFAULT_SHARD_COUNT :: 1

// The ceiling this app will accept, whatever the environment says.
//
// Ten. Not because Tina has a limit near it -- `MAX_SHARD_COUNT` is 255 -- but because a shard here
// costs a WHOLE CORE whether or not anybody is using it: the scheduler loop never blocks
// (RESULTS.md, "CPU: the axis that does not transfer"). Ten shards is ten cores of this machine's
// twenty-four burning at idle, which is as far as an experiment on a shared box has any business
// going.
MAX_SHARDS :: 10

// Whether the brotli encoder is compiled in. See README.md, "Deliberate divergences".
BROTLI_ENABLED :: #config(DSQUIZ_BROTLI, false)

Config :: struct {
	port:             u16,
	connection_slots: u32,
	shards:           u8,
	// Mount point, "" unless DSQUIZ_PREFIX is set. Applied TWICE: to route matching and to every URL
	// the templates emit. Requests have to arrive with it still attached.
	prefix:           string,
	// "client" (the browser walks the timer bar down) or "stream" (a held SSE connection pushes it).
	timer_mode:       string,
	debug:            bool,
}

//
// App-wide state, all of it written during boot and read-only afterwards.
//

config: Config

// The loaded corpus, immortal for the life of the process. Read-only after boot, which is what makes
// it safe to share when the shard count eventually goes above one.
@(private)
loaded_corpus: corpus.Corpus

// The sessions live in an ISOLATE now (`session/isolate.odin`), so there is no store here to point
// at: a handler asks for a session by message and parks. What used to be this variable is
// `store_handle()`, published by the store's own init.

// The topic picker's rows, per variant, index-aligned with `loaded_corpus.systems`. Derived from
// topic names, which never change within a process, so they are built once here rather than on every
// render -- the python's profile counted 37,868 calls a minute to the transform that builds them.
@(private)
topic_choices: [][]render.Topic_Choice

// A short fingerprint shown in the debug panel and used as the `?v=` on the sound URLs, so a changed
// synth reaches a browser holding the old file.
@(private)
build_stamp: string

config_from_environment :: proc() -> Config {
	prefix := env_string("DSQUIZ_PREFIX", "")
	if prefix != "" {
		prefix = strings.concatenate({"/", strings.trim(prefix, "/")}, context.allocator)
	}
	return Config {
		port = u16(env_int("DSQUIZ_PORT", DEFAULT_PORT)),
		connection_slots = u32(env_int("DSQUIZ_CONNECTION_SLOTS", DEFAULT_CONNECTION_SLOTS)),
		shards = shard_count_from_environment(),
		prefix = prefix,
		timer_mode = env_string("DSQUIZ_TIMER", "client"),
		debug = env_string("DSQUIZ_DEBUG", "") == "1",
	}
}

// How many shards to run, clamped to what this app and this platform will actually carry.
//
// Two ceilings, and they are different in kind:
//
//   - `MAX_SHARDS` is this app's own, and it is about cost: a Tina shard spins a core at idle.
//   - **On Windows, Tina's HTTP server is single-shard, full stop.** `install_into_system_spec`
//     asserts `spec.shard_count == 1` there ("HTTP v1 multi-shard mode is unsupported on Windows --
//     Tina core lacks cross-shard FD handoff"), and `SO_REUSEPORT` does not exist on Windows either,
//     so neither ingress mode has anything to stand on. Asking for more is refused HERE, with the
//     reason, rather than by an assert inside the framework -- the app-side work is done and
//     portable, and the platform is what is missing.
shard_count_from_environment :: proc() -> u8 {
	wanted := env_int("DSQUIZ_SHARDS", DEFAULT_SHARD_COUNT)
	if wanted < 1 {
		wanted = 1
	}
	if wanted > MAX_SHARDS {
		log.warnf("DSQUIZ_SHARDS=%d is above this app's ceiling of %d; using %d", wanted, MAX_SHARDS, MAX_SHARDS)
		wanted = MAX_SHARDS
	}
	when ODIN_OS == .Windows {
		if wanted > 1 {
			log.warnf(
				"DSQUIZ_SHARDS=%d ignored: Tina's HTTP server is single-shard on Windows (no cross-shard FD handoff, and no SO_REUSEPORT); running 1 shard",
				wanted,
			)
			wanted = 1
		}
	}
	return u8(wanted)
}

serve :: proc(configuration: Config) -> (exit_code: int) {
	config = configuration

	// Primed at boot, never lazily. `DSQUIZ_PREWARM` exists in the python because parsing the two
	// systems costs ~5.5 s there and is not something to pay on a user's first request; the
	// comparison ground rules ask every port to prime the same way. There is no lazy path here to
	// make optional, so there is no flag either.
	started := time.now()
	ok: bool
	loaded_corpus, ok = corpus.load()
	if !ok {
		log.error("the embedded corpus did not load")
		return 1
	}

	topic_choices = make([][]render.Topic_Choice, len(loaded_corpus.systems))
	for &system, index in loaded_corpus.systems {
		topic_choices[index] = render.build_topic_choices(&system)
	}

	sounds := sfx.build()
	compressed_count, saved := 0, 0
	when BROTLI_ENABLED {
		compression_init()
		compressed_count, saved = compress_assets()
	}
	// The store isolate needs the corpus to build sessions with, and a message carries a variant SLOT
	// rather than a name -- so it is handed the systems slice here, before any shard is running.
	session.register_systems(loaded_corpus.systems)
	build_stamp = fmt.aprintf("%d", time.to_unix_seconds(started))

	log.infof(
		"corpus ready in %v (%d auctions across %d systems, %d sounds, %d assets pre-compressed saving %d KB)",
		time.since(started),
		auction_total(loaded_corpus),
		len(loaded_corpus.systems),
		len(sounds),
		compressed_count,
		saved / 1024,
	)

	// The table is a package-level slice, not a literal returned from a proc: a slice literal built
	// in a call frame points at that frame's stack, and the router keeps this for the life of the
	// process.
	route_table = routes(context.allocator)
	app := http.App {
		routes = route_table,
	}

	server := http.Server {
		address      = tina.ipv4(0, 0, 0, 0, config.port),
		app          = &app,
		limits       = limits(),
		// Above one shard the kernel hands each connection to whichever shard's listener wins the
		// accept (`SO_REUSEPORT`) -- no coordinator isolate, no cross-shard FD handoff, which is the
		// half Tina does not have on every platform. `.Coordinator` is the alternative and needs
		// that handoff. NEITHER routes by cookie, which is exactly why the session store is one
		// isolate rather than one per shard.
		//
		// At one shard the mode is not consulted: Tina rejects `.Reuse_Port` below two shards and
		// binds exclusively, so this says `.Coordinator` there only because the enum has no
		// "unused".
		ingress_mode = config.shards > 1 ? .Reuse_Port : .Coordinator,
	}

	log.infof(
		"dsquiz-tina listening on http://127.0.0.1:%d%s (shards %d, connection slots %d, timer %s)",
		config.port,
		config.prefix,
		config.shards,
		config.connection_slots,
		config.timer_mode,
	)

	spec := http.install(&server, config.shards, config.connection_slots)
	if config.shards > 1 {
		attach_session_store(&spec)
	} else {
		use_local_store()
	}
	tina.tina_start(&spec)
	return 0
}

// Put the session store into the boot spec, on shard 0.
//
// HTTP's own types are appended by `install`, and it is explicit that they go "after whatever the
// caller has already registered" -- so appending one more after THAT is the same operation, and the
// type id is the index. The store is a STATIC child of shard 0's root group: one isolate for the
// whole process, permanent, restarted by the supervision tree if it ever crashes (which loses the
// sessions and is a reload for every player -- the same as a restart, which is what the resync path
// in `resolve` already exists to handle).
//
// `pool_slot_count` is raised by hand because `install` sized it against the types it knew about.
// Every parked connection is holding one envelope for its store round trip, so the pool has to carry
// the connection count on top of what HTTP asked for.
@(private = "file")
attach_session_store :: proc(spec: ^tina.SystemSpec, allocator := context.allocator) {
	store_type_id := tina.Isolate_Type_Id(len(spec.types))

	types := make([]tina.IsolateTypeDescriptor, len(spec.types) + 1, allocator)
	copy(types, spec.types)
	types[store_type_id] = tina.IsolateTypeDescriptor {
		id                      = store_type_id,
		slot_count              = 1,
		stride                  = size_of(Store_Isolate),
		soa_metadata_size       = size_of(tina.Isolate_Metadata),
		working_memory_size     = STORE_WORKING_MEMORY,
		scratch_requirement_max = STORE_SCRATCH,
		// Deep enough that a burst of connections asking at once queues rather than bouncing: every
		// one of them is parked waiting for its answer, so a refused send is a 503 for a player.
		mailbox_capacity        = STORE_MAILBOX_CAPACITY,
		init_handler            = store_isolate_init,
		handler_fn              = store_isolate_handler,
	}
	spec.types = types

	root := &spec.shard_specs[0].root_group
	children := make([]tina.Child_Spec, len(root.children) + 1, allocator)
	copy(children, root.children)
	children[len(children) - 1] = tina.Static_Child_Spec {
		type_id      = store_type_id,
		restart_type = .permanent,
	}
	root.children = children

	needed := spec.pool_slot_count + int(STORE_MAILBOX_CAPACITY) * 2
	if spec.pool_slot_count < needed {
		spec.pool_slot_count = next_power_of_two(needed)
	}

	// And the TIMER WHEEL, which is the one `install` cannot size for this app any more.
	//
	// It sized it at one entry per connection slot, which was right when the only thing a connection
	// waited for was a toast's pause. Every request now also arms the store round trip's timeout, and
	// a connection can hold both at once. When the wheel is full the timeout is simply never armed --
	// no error, no reply, and the connection parks until the CLIENT gives up. Measured before this
	// line existed: 400 users, a fifth of every session-touching route sitting at 50-60 s while the
	// asset routes stayed at 1 ms.
	timers_wanted := int(config.connection_slots) * TIMERS_PER_CONNECTION
	if spec.timer_entry_count < timers_wanted {
		spec.timer_entry_count = timers_wanted
	}
}

// Two in flight per connection -- a pause and a store round trip -- and twice that as headroom, at
// about 88 bytes of wheel per entry.
@(private = "file")
TIMERS_PER_CONNECTION :: 4

@(private = "file")
STORE_MAILBOX_CAPACITY :: u16(4096)
@(private = "file")
STORE_WORKING_MEMORY :: 64 * 1024
@(private = "file")
STORE_SCRATCH :: 16 * 1024

@(private = "file")
next_power_of_two :: proc(value: int) -> int {
	out := 1
	for out < value {
		out *= 2
	}
	return out
}

// Every signal-reading POST needs `body_mode = .Buffered` with a non-zero `body_size_max`, or
// `http.body_buffered` returns nil and `read_signals` reports `.Missing` for a perfectly good
// payload. The uploaded set is ~475 bytes before the topic ticks; 8 KB is generous for the widest
// variant's picker.
@(private = "file")
SIGNALS_BODY_MAX :: 8192

@(private = "file")
route_table: []http.Route

@(private = "file")
routes :: proc(allocator := context.allocator) -> []http.Route {
	p :: proc(path: string) -> string {
		return strings.concatenate({config.prefix, path}, context.allocator)
	}
	state :: size_of(Stream_State)

	table := []http.Route {
		// The page. Streamed, because the document is far larger than the egress buffer.
		http.get_event(p("/"), route_index, state_size = state),

		// The answer choreography, and the actions that share its view patches.
		http.post_event(
			p("/answer/:qid/:index"),
			route_answer,
			state_size = state,
			body_size_max = SIGNALS_BODY_MAX,
			body_mode = .Buffered,
		),
		http.post_event(
			p("/next"),
			route_next,
			state_size = state,
			body_size_max = SIGNALS_BODY_MAX,
			body_mode = .Buffered,
		),
		http.post_event(
			p("/skip"),
			route_skip,
			state_size = state,
			body_size_max = SIGNALS_BODY_MAX,
			body_mode = .Buffered,
		),
		http.post_event(
			p("/restart"),
			route_restart,
			state_size = state,
			body_size_max = SIGNALS_BODY_MAX,
			body_mode = .Buffered,
		),
		http.post_event(
			p("/settings"),
			route_settings,
			state_size = state,
			body_size_max = SIGNALS_BODY_MAX,
			body_mode = .Buffered,
		),

		// The held countdown. 204 unless DSQUIZ_TIMER=stream.
		http.get_event(p("/timer"), route_timer, state_size = size_of(Timer_State)),

		// The filter and the topic picker.
		http.get_event(p("/filter/preview"), route_filter_preview, state_size = state),
		http.get_event(p("/filter/preview-topics"), route_topics_preview, state_size = state),
		http.get_event(p("/filter/topics-reset"), route_topics_reset, state_size = state),
		http.post_event(
			p("/filter/apply"),
			route_filter_apply,
			state_size = state,
			body_size_max = SIGNALS_BODY_MAX,
			body_mode = .Buffered,
		),
		http.post_event(
			p("/filter/apply-topics"),
			route_topics_apply,
			state_size = state,
			body_size_max = SIGNALS_BODY_MAX,
			body_mode = .Buffered,
		),

		// The debug panel, every route of which 204s unless the session is armed.
		http.post_event(
			p("/debug/points/:delta"),
			route_debug_points,
			state_size = state,
			body_size_max = SIGNALS_BODY_MAX,
			body_mode = .Buffered,
		),
		http.post_event(
			p("/debug/goal/:value"),
			route_debug_goal,
			state_size = state,
			body_size_max = SIGNALS_BODY_MAX,
			body_mode = .Buffered,
		),
		http.post_event(
			p("/debug/complete"),
			route_debug_complete,
			state_size = state,
			body_size_max = SIGNALS_BODY_MAX,
			body_mode = .Buffered,
		),
		http.post_event(
			p("/debug/reveal"),
			route_debug_reveal,
			state_size = state,
			body_size_max = SIGNALS_BODY_MAX,
			body_mode = .Buffered,
		),

		// Assets and sounds.
		http.get_event(p("/sfx/:name"), route_sfx, state_size = size_of(Asset_Stream)),
		http.get_event(p("/static/:name"), serve_static, state_size = size_of(Asset_Stream)),
		http.get_event(p("/media/:name"), serve_media, state_size = size_of(Asset_Stream)),
		http.get(p("/health"), health),
	}
	out := make([]http.Route, len(table), allocator)
	copy(out, table)
	return out
}

// Tina's DEFAULT_LIMITS are sized for an ordinary REST service and two of them are too small here,
// both because of how Datastar uploads signals. On a GET it sends them as `?datastar=<json>`, and
// this app's signal set is ~475 bytes before percent-encoding -- against a 2048-byte default request
// line. `read_signals` then unmarshals that JSON out of the handler's scratch arena, against a
// 2048-byte default.
@(private = "file")
limits :: proc() -> http.Limits {
	tuned := http.DEFAULT_LIMITS
	tuned.request_line_size_max = 8192
	tuned.handler_scratch_max = 32768
	return tuned
}

@(private = "file")
health :: proc(request: ^http.Request, response: ^http.Response) -> http.Route_Step {
	// The store's tally rides along: it is the one place the session round trip is visible from
	// outside, and "acquires minus answered minus queued" is the number that should always be zero.
	counters := store_counters()
	body := fmt.tprintf(
		"ok acquires=%d answered=%d queued=%d woken=%d releases=%d peeks=%d failed=%d",
		counters.acquires,
		counters.answered,
		counters.queued,
		counters.woken,
		counters.releases,
		counters.peeks,
		counters.failed,
	)
	return http.respond_text(response, http.HTTP_STATUS_OK, body)
}

// The picker rows for a system, found by identity rather than by key -- there are two systems.
@(private)
choices_for :: proc(system: ^corpus.System) -> []render.Topic_Choice {
	for &candidate, index in loaded_corpus.systems {
		if &candidate == system {
			return topic_choices[index]
		}
	}
	return nil
}

@(private)
render_context :: proc() -> render.Context {
	return render.Context {
		prefix = config.prefix,
		cookie_path = cookie_path(),
		timer_mode = config.timer_mode,
		build_stamp = build_stamp,
	}
}

@(private = "file")
auction_total :: proc(loaded: corpus.Corpus) -> (total: int) {
	for system in loaded.systems {
		total += len(system.auctions)
	}
	return total
}

@(private = "file")
env_int :: proc(name: string, fallback: int) -> int {
	raw, found := os.lookup_env(name, context.temp_allocator)
	if !found {
		return fallback
	}
	value, ok := strconv.parse_int(strings.trim_space(raw))
	if !ok {
		log.warnf("%s is not a number (%q), using %d", name, raw, fallback)
		return fallback
	}
	return value
}

@(private = "file")
env_string :: proc(name, fallback: string) -> string {
	raw, found := os.lookup_env(name, context.allocator)
	if !found || strings.trim_space(raw) == "" {
		return fallback
	}
	return strings.trim_space(raw)
}
