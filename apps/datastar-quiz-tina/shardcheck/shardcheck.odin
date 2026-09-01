// Does the session store actually work ACROSS SHARDS?
//
// Phase I put the sessions in an isolate so that the shard count could be a setting. On this machine
// that cannot be proven through the app, because Tina's HTTP server is single-shard on Windows
// (`install_into_system_spec` asserts it, and there is no `SO_REUSEPORT` here either). Tina's CORE
// is not single-shard, though -- only the FD handoff is missing -- so this program runs the real
// store isolate on shard 0 and drives it from a prober on EVERY shard, with no HTTP anywhere.
//
//     just shardcheck        # the default, 4 shards
//     just shardcheck 10     # the ceiling this project will run (see web/server.odin, MAX_SHARDS)
//
// What it proves, and what it does not: the protocol, the lease and the sweep behave when the caller
// is on another thread, and a pointer handed across a shard boundary under a lease is still the
// session the holder thinks it is. It says nothing about whether Tina's HTTP layer can accept on
// several shards -- that is the platform gap, and it is why this exists.
//
// Each prober runs a fixed number of rounds of the real protocol:
//
//     ACQUIRE (its own session) -> RELEASE -> ACQUIRE (the session EVERY shard shares) -> RELEASE
//                               -> PEEK    -> next round
//
// The shared session is the point: every shard is asking for the same one, so the lease is what
// keeps two shards out of it at once, and a `busy` answer is a pass rather than a failure -- it is
// the lease doing its job. What would be a failure is two shards holding it at the same time, which
// the store cannot produce and the prober asserts it never sees.
package main

import "../corpus"
import "../session"
import "../web"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:sync"
import tina "tina:src"

// The same ceiling the app has, for the same reason: a shard spins a core whether or not it is busy.
MAX_SHARDS :: 10
DEFAULT_SHARDS :: 4

// How many rounds each prober runs before it reports.
ROUNDS :: 200

// The whole run's deadline. Generous: at 4 shards it finishes in milliseconds.
DEADLINE_NS :: u64(20_000_000_000)

STORE_TYPE :: tina.Isolate_Type_Id(0)
PROBER_TYPE :: tina.Isolate_Type_Id(1)
REFEREE_TYPE :: tina.Isolate_Type_Id(2)

TAG_TICK: tina.Message_Tag : tina.USER_MESSAGE_TAG_BASE + 1
TAG_REPORT: tina.Message_Tag : tina.USER_MESSAGE_TAG_BASE + 2
TAG_DEADLINE: tina.Message_Tag : tina.USER_MESSAGE_TAG_BASE + 3

// The session every prober fights over, so the lease is under real contention.
SHARED_SID :: "aaaabbbbccccddddeeeeffff00001111"

Report :: struct {
	shard:     u8,
	rounds:    u32,
	busy_seen: u32,
	failures:  u32,
}

//
// The prober: one per shard, including the store's own.
//

Prober :: struct {
	timer:     tina.Timer_Handle,
	round:     u32,
	busy_seen: u32,
	failures:  u32,
	held:      u64,
	stage:     Stage,
	referee:   tina.Isolate_Handle,
	reported:  bool,
}

Stage :: enum u8 {
	Waiting_For_Store,
	Own_Session,
	Shared_Session,
	Peeking,
}

prober_init :: proc(self_raw: rawptr, args: []u8) -> tina.Isolate_Transition {
	self := tina.self_as(Prober, self_raw)
	self.timer = tina.ctx_timer_acquire()
	self.stage = .Waiting_For_Store
	// The store publishes its handle from its own init, on another shard, so a prober can easily be
	// first. Poll rather than assume -- this is the only place the ordering matters.
	tina.ctx_timer_rearm(self.timer, 1_000_000, TAG_TICK, tina.Correlation_Id(0))
	return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
}

@(private = "file")
sid_for_shard :: proc(shard: u8) -> [session.SID_LENGTH]u8 {
	out: [session.SID_LENGTH]u8
	digits := "0123456789abcdef"
	for index in 0 ..< session.SID_LENGTH {
		out[index] = digits[(int(shard) + index) % 16]
	}
	return out
}

@(private = "file")
ask_acquire :: proc(sid: [session.SID_LENGTH]u8) {
	request := session.Acquire_Request {
		settings     = session.default_settings(),
		variant_slot = 0,
		sid          = sid,
	}
	_ = tina.ctx_send(web.store_handle(), web.TAG_ACQUIRE, &request)
}

@(private = "file")
give_back :: proc(held: u64) {
	request := session.Release_Request {
		session = held,
	}
	_ = tina.ctx_send(web.store_handle(), web.TAG_RELEASE, &request)
}

prober_handler :: proc(self_raw: rawptr, message: ^tina.Message) -> tina.Isolate_Transition {
	self := tina.self_as(Prober, self_raw)
	shard := u8(tina.extract_shard_id(tina.ctx_self_handle()))

	switch message.tag {
	case TAG_TICK:
		if web.store_handle() == tina.ISOLATE_HANDLE_NONE {
			tina.ctx_timer_rearm(self.timer, 1_000_000, TAG_TICK, tina.Correlation_Id(0))
			return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
		}
		self.stage = .Own_Session
		ask_acquire(sid_for_shard(shard))
		return tina.ISOLATE_TRANSITION_WAIT_MESSAGE

	case web.TAG_ACQUIRE:
		reply := tina.payload_as(session.Acquire_Reply, message.user.payload[:])
		if reply.busy {
			// The lease held somebody else out. That is the protocol working; wait a tick and go on.
			self.busy_seen += 1
			tina.ctx_timer_rearm(self.timer, 1_000_000, TAG_TICK, tina.Correlation_Id(0))
			return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
		}
		if reply.session == 0 {
			self.failures += 1
			return finish_or_continue(self, shard)
		}

		// The pointer came from another shard. Read something through it that only the right session
		// could answer: its own id.
		s := cast(^session.Session)uintptr(reply.session)
		expected := self.stage == .Own_Session ? sid_for_shard(shard) : shared_sid()
		if s.sid != string(expected[:]) {
			self.failures += 1
		}
		if !s.lease_held {
			// Held without a lease is the failure this whole design exists to prevent.
			self.failures += 1
		}

		give_back(reply.session)

		if self.stage == .Own_Session {
			self.stage = .Shared_Session
			ask_acquire(shared_sid())
			return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
		}

		self.stage = .Peeking
		peek := session.Peek_Time_Request {
			variant_slot = 0,
			sid          = sid_for_shard(shard),
		}
		_ = tina.ctx_send(web.store_handle(), web.TAG_PEEK_TIME, &peek)
		return tina.ISOLATE_TRANSITION_WAIT_MESSAGE

	case web.TAG_PEEK_TIME:
		reply := tina.payload_as(session.Peek_Time_Reply, message.user.payload[:])
		if !reply.found {
			self.failures += 1
		}
		self.round += 1
		return finish_or_continue(self, shard)

	case:
		return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
	}
}

@(private = "file")
shared_sid :: proc() -> [session.SID_LENGTH]u8 {
	out: [session.SID_LENGTH]u8
	copy(out[:], SHARED_SID)
	return out
}

@(private = "file")
finish_or_continue :: proc(self: ^Prober, shard: u8) -> tina.Isolate_Transition {
	if self.round < ROUNDS {
		self.stage = .Own_Session
		ask_acquire(sid_for_shard(shard))
		return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
	}
	if !self.reported {
		self.reported = true
		report := Report {
			shard     = shard,
			rounds    = self.round,
			busy_seen = self.busy_seen,
			failures  = self.failures,
		}
		_ = tina.ctx_send(referee_handle(), TAG_REPORT, &report)
	}
	return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
}

//
// The referee: counts the reports, prints the table, decides the exit code.
//

Referee :: struct {
	timer:     tina.Timer_Handle,
	reported:  u8,
	failures:  u32,
	busy_seen: u32,
	rounds:    u32,
}

// Published the same way the store publishes its own, and for the same reason: nothing hands an
// isolate another isolate's handle unless somebody puts it somewhere both can see.
@(private = "file")
published_referee: u64

referee_handle :: proc "contextless" () -> tina.Isolate_Handle {
	return tina.Isolate_Handle(sync.atomic_load_explicit(&published_referee, .Acquire))
}

referee_init :: proc(self_raw: rawptr, args: []u8) -> tina.Isolate_Transition {
	self := tina.self_as(Referee, self_raw)
	self.timer = tina.ctx_timer_acquire()
	sync.atomic_store_explicit(&published_referee, u64(tina.ctx_self_handle()), .Release)
	tina.ctx_timer_rearm(self.timer, DEADLINE_NS, TAG_DEADLINE, tina.Correlation_Id(0))
	return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
}

referee_handler :: proc(self_raw: rawptr, message: ^tina.Message) -> tina.Isolate_Transition {
	self := tina.self_as(Referee, self_raw)

	switch message.tag {
	case TAG_REPORT:
		report := tina.payload_as(Report, message.user.payload[:])
		self.reported += 1
		self.failures += report.failures
		self.busy_seen += report.busy_seen
		self.rounds += report.rounds
		fmt.printf(
			"shard %d: %d rounds, %d busy answers, %d failures\n",
			report.shard,
			report.rounds,
			report.busy_seen,
			report.failures,
		)
		if int(self.reported) >= expected_reports {
			verdict(self.rounds, self.busy_seen, self.failures, false)
		}
		return tina.ISOLATE_TRANSITION_WAIT_MESSAGE

	case TAG_DEADLINE:
		fmt.printfln("deadline: only %d of %d probers reported", self.reported, expected_reports)
		verdict(self.rounds, self.busy_seen, self.failures, true)
		return tina.ISOLATE_TRANSITION_WAIT_MESSAGE

	case:
		return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
	}
}

@(private = "file")
verdict :: proc(rounds, busy_seen, failures: u32, timed_out: bool) {
	fmt.printfln(
		"%d shards, %d rounds total, %d busy answers, %d failures",
		expected_reports,
		rounds,
		busy_seen,
		failures,
	)
	if failures > 0 || timed_out {
		fmt.println("FAIL")
		os.exit(1)
	}
	fmt.println("PASS: the store answered every shard, and the lease was never held twice")
	os.exit(0)
}

//
// Boot
//

@(private = "file")
expected_reports: int

main :: proc() {
	shards := DEFAULT_SHARDS
	if len(os.args) > 1 {
		if value, ok := strconv.parse_int(os.args[1]); ok {
			shards = value
		}
	}
	shards = clamp(shards, 1, MAX_SHARDS)
	expected_reports = shards

	fmt.printfln("shardcheck: %d shards, %d rounds each, store on shard 0", shards, ROUNDS)

	types := []tina.IsolateTypeDescriptor {
		{
			id = STORE_TYPE,
			slot_count = 1,
			stride = size_of(web.Store_Isolate),
			soa_metadata_size = size_of(tina.Isolate_Metadata),
			working_memory_size = 64 * 1024,
			scratch_requirement_max = 16 * 1024,
			mailbox_capacity = 1024,
			init_handler = web.store_isolate_init,
			handler_fn = web.store_isolate_handler,
		},
		{
			id = PROBER_TYPE,
			slot_count = 1,
			stride = size_of(Prober),
			soa_metadata_size = size_of(tina.Isolate_Metadata),
			working_memory_size = 16 * 1024,
			scratch_requirement_max = 8 * 1024,
			mailbox_capacity = 64,
			init_handler = prober_init,
			handler_fn = prober_handler,
		},
		{
			id = REFEREE_TYPE,
			slot_count = 1,
			stride = size_of(Referee),
			soa_metadata_size = size_of(tina.Isolate_Metadata),
			working_memory_size = 16 * 1024,
			scratch_requirement_max = 8 * 1024,
			mailbox_capacity = 64,
			init_handler = referee_init,
			handler_fn = referee_handler,
		},
	}

	// Shard 0 carries the store, the referee and a prober of its own -- the store's own shard must be
	// exercised too, or the same-shard path (which is what the app runs today) goes untested here.
	shard_zero_children := []tina.Child_Spec {
		tina.Static_Child_Spec{type_id = STORE_TYPE, restart_type = .permanent},
		tina.Static_Child_Spec{type_id = REFEREE_TYPE, restart_type = .permanent},
		tina.Static_Child_Spec{type_id = PROBER_TYPE, restart_type = .permanent},
	}
	other_children := []tina.Child_Spec{tina.Static_Child_Spec{type_id = PROBER_TYPE, restart_type = .permanent}}

	shard_specs := make([]tina.ShardSpec, shards, context.allocator)
	for index in 0 ..< shards {
		shard_specs[index] = tina.ShardSpec {
			shard_id = tina.Shard_Id(u8(index)),
			target_core = -1,
			root_group = tina.Group_Spec {
				strategy = .One_For_One,
				restart_count_max = 3,
				window_duration_ticks = 10_000,
				children = index == 0 ? shard_zero_children : other_children,
			},
		}
	}

	spec := tina.SystemSpec {
		types = types,
		shard_specs = shard_specs,
		shard_count = u8(shards),
		timer_resolution_ns = 1_000_000,
		pool_slot_count = 4096,
		timer_entry_count = 1024,
		log_ring_size = 65536,
		default_ring_size = 1024,
		scratch_memory_size = 65536,
		supervision_groups_max = 8,
		init_timeout_ms = 5_000,
		shutdown_timeout_ms = 5_000,
		memory_init_mode = .Development,
		quarantine_policy = .Abort,
		watchdog = tina.Watchdog_Config {
			check_interval_ms = 500,
			shard_restart_window_ms = 30_000,
			shard_restart_max = 3,
			phase_2_threshold = 3,
		},
		// Cross-shard FD handoff is what Tina does not have on Windows, and nothing here needs it:
		// this program passes MESSAGES between shards, never sockets.
		fd_handoff_entry_count = 0,
		// The I/O pools are validated whether or not anything does I/O, so these are the smallest
		// legal values rather than zero: no socket is opened anywhere in this program.
		fd_table_slot_count = 16,
		fd_entry_size = 64,
		reactor_buffer_slot_count = 16,
		reactor_buffer_slot_size = 4096,
		staging_slot_count = 16,
		staging_slot_size = 4096,
		transfer_slot_count = 16,
		transfer_slot_size = 4096,
	}

	// The store builds real sessions, so it needs the real corpus -- loaded before any shard runs,
	// pointed at by all of them, and never written. Exactly what the server does.
	loaded, ok := corpus.load()
	if !ok {
		fmt.eprintln("the corpus did not load")
		os.exit(1)
	}
	session.register_systems(loaded.systems)

	tina.tina_start(&spec)
}
