// The HTTP surface of the quiz: configuration, the route table, and boot.
//
// odin-http asks almost nothing of an application's shape, which is the interesting half of this
// port. There is no compile-time buffer to size, no per-connection state to declare, no ceiling to
// bisect: a handler is `proc(req, res)`, a response body is a string, and every buffer grows from a
// per-connection arena the library frees when the response is sent. Everything the sibling Tina port
// has to decide up front -- egress buffer, route state size, connection slot count -- simply does
// not appear here. What that costs is the other half, and it is measured in RESULTS.md rather than
// argued about here.
//
// Two things this app does need from it are set below: a raised request-line limit, because Datastar
// uploads its whole signal store as `?datastar=<json>` on a GET, and a thread count that defaults to
// ONE so the numbers are comparable with the python's single asyncio loop.
package web

import "../corpus"
import "../render"
import "../session"
import "../sfx"
import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import http "odinhttp:."

// Port 5062. The python serves 5008, the Go port 5060 and the Tina port 5061, and all of them are
// driven by the same `apps/dsquiz-perf` harness, so they need to run side by side.
DEFAULT_PORT :: 5062

// One event-loop thread by default.
//
// odin-http's own default is `cores - 1`, which is the deployment answer and the wrong one for a
// comparison: the python has a single asyncio loop, the Tina port runs one shard, and the Go and
// Rust ports are measured with `serve-1core`. `DSQUIZ_THREADS=0` asks for odin-http's default,
// anything else is taken literally (`just serve-all-cores`).
DEFAULT_THREADS :: 1

// Whether the brotli encoder is compiled in. See README.md, "Deliberate divergences".
BROTLI_ENABLED :: #config(DSQUIZ_BROTLI, false)

Config :: struct {
	port:       u16,
	threads:    int,
	// Mount point, "" unless DSQUIZ_PREFIX is set. Applied TWICE: to route matching and to every URL
	// the templates emit. Requests have to arrive with it still attached.
	prefix:     string,
	// "client" (the browser walks the timer bar down) or "stream" (a held SSE connection pushes it).
	timer_mode: string,
	debug:      bool,
}

//
// App-wide state, all of it written during boot and read-only afterwards -- except the session
// store, which every request writes and `store_lock` guards.
//

config: Config

// The loaded corpus, immortal for the life of the process. Read-only after boot, so every thread
// shares it; the filter MEMO in front of it is `@(thread_local)` and needs no lock either.
@(private)
loaded_corpus: corpus.Corpus

// The sessions, and the one lock in the app.
//
// The Tina port needs neither: one shard owns the store and runs every handler on its own thread. An
// odin-http server is threads over shared memory, so the map and the sessions in it are ordinary
// shared mutable state -- the same position the Go port is in, which guards it with a mutex, and the
// Rust port, which uses `parking_lot`. Held across the whole BUILD phase of a request (resolve,
// mutate, render) and never across the stream, because every route mutates its session fully before
// the first byte goes out.
@(private)
store: session.Store

@(private)
store_lock: sync.Mutex

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
		threads = env_int("DSQUIZ_THREADS", DEFAULT_THREADS),
		prefix = prefix,
		timer_mode = env_string("DSQUIZ_TIMER", "client"),
		debug = env_string("DSQUIZ_DEBUG", "") == "1",
	}
}

serve :: proc(configuration: Config) -> (exit_code: int) {
	config = configuration

	// Primed at boot, never lazily. `DSQUIZ_PREWARM` exists in the python because parsing the two
	// systems costs ~5.5 s there and is not something to pay on a user's first request; the
	// comparison ground rules ask every port to prime the same way.
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
	init_assets()
	compressed_count, saved := 0, 0
	when BROTLI_ENABLED {
		compression_init()
		compressed_count, saved = compress_assets()
	}
	store = session.make_store()
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

	router: http.Router
	http.router_init(&router)
	install_routes(&router)

	server: http.Server
	http.server_shutdown_on_interrupt(&server)

	options := http.Default_Server_Opts
	options.thread_count = config.threads
	// Datastar sends the whole signal store as `?datastar=<json>` on a GET, and this app's set is
	// ~475 bytes before percent-encoding and before the topic ticks. odin-http's 8000-byte default
	// is generous enough for the widest variant's picker, but the headroom is worth stating: the
	// python and the Tina port both had to raise their own limits for exactly this.
	options.limit_request_line = 16384

	log.infof(
		"dsquiz-odin-http listening on http://127.0.0.1:%d%s (threads %d, timer %s)",
		config.port,
		config.prefix,
		config.threads,
		config.timer_mode,
	)

	error := http.listen_and_serve(
		&server,
		http.router_handler(&router),
		net.Endpoint{address = net.IP4_Any, port = int(config.port)},
		options,
	)
	if error != nil {
		log.errorf("server stopped with error: %v", error)
		return 1
	}
	return 0
}

@(private = "file")
install_routes :: proc(router: ^http.Router) {
	http.route_get(router, path("/"), http.handler(route_index))

	// The answer choreography, and the actions that share its view patches.
	http.route_post(router, path("/answer/(%d+)/(%d+)"), http.handler(route_answer))
	http.route_post(router, path("/next"), http.handler(route_next))
	http.route_post(router, path("/skip"), http.handler(route_skip))
	http.route_post(router, path("/restart"), http.handler(route_restart))
	http.route_post(router, path("/settings"), http.handler(route_settings))

	// The held countdown. 204 unless DSQUIZ_TIMER=stream.
	http.route_get(router, path("/timer"), http.handler(route_timer))

	// The filter and the topic picker.
	http.route_get(router, path("/filter/preview"), http.handler(route_filter_preview))
	http.route_get(router, path("/filter/preview%-topics"), http.handler(route_topics_preview))
	http.route_get(router, path("/filter/topics%-reset"), http.handler(route_topics_reset))
	http.route_post(router, path("/filter/apply"), http.handler(route_filter_apply))
	http.route_post(router, path("/filter/apply%-topics"), http.handler(route_topics_apply))

	// The debug panel, every route of which 204s unless the session is armed.
	http.route_post(router, path("/debug/points/(%-?%d+)"), http.handler(route_debug_points))
	http.route_post(router, path("/debug/goal/(%d+)"), http.handler(route_debug_goal))
	http.route_post(router, path("/debug/complete"), http.handler(route_debug_complete))
	http.route_post(router, path("/debug/reveal"), http.handler(route_debug_reveal))

	// Assets and sounds.
	http.route_get(router, path("/sfx/(.*)"), http.handler(route_sfx))
	http.route_get(router, path("/static/(.*)"), http.handler(route_static))
	http.route_get(router, path("/media/(.*)"), http.handler(route_media))
	http.route_get(router, path("/health"), http.handler(route_health))
}

// A route pattern under the mount prefix.
//
// odin-http matches with Lua patterns rather than a path syntax, which is a real trap for a route
// table written by hand: `-` is the LAZY REPEAT quantifier there, so `/filter/preview-topics` reads
// as "prefi", zero-or-more "w", then "topics" and matches nothing anybody types. The literal dashes
// above are escaped as `%-` for that reason; the prefix is escaped here because a mount point is
// somebody's environment variable and may contain anything.
@(private = "file")
path :: proc(pattern: string) -> string {
	if config.prefix == "" {
		return pattern
	}
	return strings.concatenate({escape_pattern(config.prefix), pattern}, context.allocator)
}

// Escape the characters Lua patterns treat as magic, so a literal string matches itself.
@(private = "file")
escape_pattern :: proc(literal: string) -> string {
	out := strings.builder_make(0, len(literal) + 8, context.allocator)
	for index in 0 ..< len(literal) {
		switch literal[index] {
		case '^', '$', '*', '+', '?', '.', '(', ')', '[', ']', '%', '-':
			strings.write_byte(&out, '%')
		}
		strings.write_byte(&out, literal[index])
	}
	return strings.to_string(out)
}

@(private = "file")
route_health :: proc(request: ^http.Request, response: ^http.Response) {
	http.respond_plain(response, "ok")
}

//
// The session store, behind its lock
//

@(private)
store_get_or_create :: proc(
	sid: string,
	system: ^corpus.System,
	settings: session.Settings,
) -> (
	found: ^session.Session,
	replaced: bool,
) {
	return session.store_get_or_create(&store, sid, system, settings)
}

//
// Shared helpers
//

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
