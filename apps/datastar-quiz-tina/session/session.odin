// One player's quiz: the settings they chose, the ledger, the working set, and the question they are
// looking at right now.
//
// A session belongs to a (browser, variant) pair, not to a connection: the same person can have the
// squad quiz open in one tab and the swedish quiz in another, and they are two independent games
// sharing one cookie.
package session

import "../corpus"
import "../engine"
import "core:sync"
import "core:time"

// How long a session outlives its last request.
TTL :: 6 * time.Hour

// How often the store looks for expired sessions. Lazily, on a request, rather than on a timer:
// there is nothing to sweep when nobody is playing.
SWEEP_INTERVAL :: 10 * time.Minute

COOKIE_NAME :: "dsq_sid"

// What the browser owns and uploads on every request.
Settings :: struct {
	difficulty:  int, // clamped to [MIN_DIFFICULTY, MAX_DIFFICULTY]
	ladder_mode: bool,
	target_on:   bool,
	target_pct:  int, // clamped to [70, 90]
}

default_settings :: proc "contextless" () -> Settings {
	return Settings{difficulty = engine.INITIAL_DIFFICULTY, ladder_mode = true, target_on = false, target_pct = 70}
}

clamp_settings :: proc "contextless" (settings: Settings) -> Settings {
	out := settings
	out.difficulty = engine.clamp_difficulty(settings.difficulty)
	out.target_pct = clamp(settings.target_pct, 70, 90)
	return out
}

Session :: struct {
	sid:                 string, // identifies the BROWSER, not this game
	system:              ^corpus.System,
	settings:            Settings,
	score:               engine.Score,

	// The auctions this game draws from: every index of the system, or the filter's hit list. Shared
	// with the filter memo rather than copied -- a filtered swedish session would otherwise hold
	// thousands of indices of its own.
	working_set:         []u32,
	question:            engine.Question,

	// From the PROCESS-WIDE counter, not a per-session one. Two per-session counters both starting
	// at 1 was a real bug: an answer posted from a stale page scored against a question that had
	// never been shown, because the qid matched by coincidence.
	qid:                 u64,
	skips_left:          int,
	last_correct_points: int,

	// The canonical text of the filter in force -- what the box shows, not what is being typed.
	filter_text:         string,
	points_goal:         int,
	debug:               bool,
	quiz_start_wall:     time.Time,
	completion_wall:     time.Time,
	has_completed:       bool,
	// When the current question reached the player. The clock starts when the question ARRIVES, not
	// when it was drawn, which is why the answer stream restarts it after the toasts.
	question_start:      time.Time,
	question_seconds:    f64,
	touched:             time.Time,

	// Parked on a reveal, waiting for Next.
	awaiting_next:       bool,
	wrong_index:         int,
	has_wrong_index:     bool,

	// The debug panel can stop the clock. `-1` when it is running normally.
	frozen_time_left:    int,

	// The LEASE. Set while one connection isolate is inside this session, cleared when it gives it
	// back. It is what makes it safe for the store to hand a POINTER to another shard: while it is
	// held nobody else is given the same session, and the sweep leaves it alone. `isolate.odin` has
	// the whole story, including why a lease is only ever held for the length of one handler call.
	lease_held:          bool,
	lease_taken:         time.Time,
}

// The process-wide question nonce. See `Session.qid`.
//
// PROCESS-wide, not per shard, and that is the whole point of it: two per-session counters both
// starting at 1 was a real bug. So this is the one piece of mutable state in the app that several
// shards touch, and it is atomic rather than thread-local for the same reason -- a per-shard counter
// would hand two sessions the same nonce again, on different shards this time.
@(private)
next_qid: u64 = 0

@(private)
take_qid :: proc() -> u64 {
	return sync.atomic_add(&next_qid, 1) + 1
}

make_session :: proc(
	sid: string,
	system: ^corpus.System,
	settings: Settings,
	allocator := context.allocator,
) -> ^Session {
	session := new(Session, allocator)
	session.sid = sid
	session.system = system
	session.settings = clamp_settings(settings)
	session.score = engine.make_score(allocator)
	session.points_goal = engine.POINTS_GOAL
	session.frozen_time_left = -1
	restart(session, allocator)
	return session
}

// Begin a fresh quiz on the current settings and filter, keeping the identity and the filter text.
restart :: proc(session: ^Session, allocator := context.allocator) {
	engine.reset_score(&session.score)
	session.skips_left = engine.INITIAL_SKIPS
	session.last_correct_points = 0
	session.awaiting_next = false
	session.has_wrong_index = false
	session.has_completed = false
	session.quiz_start_wall = time.now()
	refresh_working_set(session)
	new_question(session, allocator)
}

// Point the session at the auctions its filter selects, or at the whole system when the filter is
// empty or unusable.
//
// `min_hits` is the hardest question the player could ask for, not their current difficulty: a
// filter that cannot fill an eight-candidate question is `too_few` and falls back to the whole
// system, so that raising the difficulty mid-quiz never strands the generator.
refresh_working_set :: proc(session: ^Session) {
	check := corpus.check_filter(session.system, session.filter_text, engine.MAX_DIFFICULTY)
	session.working_set = corpus.filter_usable(check^) ? check.hits : session.system.all
}

new_question :: proc(session: ^Session, allocator := context.allocator) {
	session.question = engine.new_question(
		session.system.auctions,
		session.working_set,
		session.settings.difficulty,
		allocator,
	)
	session.qid = take_qid()
	session.awaiting_next = false
	session.has_wrong_index = false
	start_question_clock(session)
}

// The clock starts when the question REACHES the player -- after the answer stream's toasts have
// been paced out, not when the question was drawn.
start_question_clock :: proc(session: ^Session) {
	session.question_start = time.now()
	session.question_seconds = engine.seconds_for_difficulty(session.settings.difficulty)
}

still_playing :: proc "contextless" (session: ^Session) -> bool {
	return !session.has_completed
}

// Playing, and not parked on a reveal. The countdown only runs here.
on_the_clock :: proc "contextless" (session: ^Session) -> bool {
	return still_playing(session) && !session.awaiting_next
}

elapsed_seconds :: proc(session: ^Session) -> f64 {
	return time.duration_seconds(time.since(session.question_start))
}

percent_time_left :: proc(session: ^Session) -> int {
	if session.frozen_time_left >= 0 {
		return session.frozen_time_left
	}
	if !on_the_clock(session) {
		return 0
	}
	return engine.percent_time_left(elapsed_seconds(session), session.question_seconds)
}

// How long the whole quiz has taken: to now while playing, to the finish once completed.
quiz_seconds :: proc(session: ^Session) -> f64 {
	finish := session.has_completed ? session.completion_wall : time.now()
	return time.duration_seconds(time.diff(session.quiz_start_wall, finish))
}

complete :: proc(session: ^Session) {
	session.has_completed = true
	session.completion_wall = time.now()
}
