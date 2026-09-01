// Where sessions live.
//
// EVERY read and write goes through this file, even where a direct map lookup would do. On one shard
// these are plain calls into a map the shard owns. Tina is shared-nothing thread-per-core, though,
// and the multi-shard step turns the store into an isolate that connection isolates reach by
// message: `store_get` becomes an `expect_reply` and a resume. That rewrite is cheap only if no
// caller has reached past this interface, so none does. The Go port funnels everything through
// `Session.With` for the same reason.
//
// No lock, and none needed today: one shard owns the store and runs every handler on one thread.
package session

import "../corpus"
import "base:runtime"
import "core:math/rand"
import "core:strings"
import "core:time"

// A session belongs to a (browser, variant) pair. One person with the squad quiz in one tab and the
// swedish quiz in another has two independent games behind one cookie.
Key :: struct {
	sid:     string,
	variant: string,
}

Store :: struct {
	sessions:   map[Key]^Session,
	last_sweep: time.Time,
	allocator:  runtime.Allocator,
}

make_store :: proc(allocator := context.allocator) -> Store {
	return Store{sessions = make(map[Key]^Session, 64, allocator), last_sweep = time.now(), allocator = allocator}
}

// The session for this browser and variant, if it still exists.
//
// `found = false` is not an error: it is a browser whose cookie names a session the store has swept,
// or has never seen. The caller answers that with a fresh session and a resync patch rather than a
// failure, which is what makes a restarted server look like a reload rather than a crash.
store_get :: proc(store: ^Store, key: Key) -> (session: ^Session, found: bool) {
	sweep_if_due(store)
	session, found = store.sessions[key]
	if found {
		session.touched = time.now()
	}
	return session, found
}

store_put :: proc(store: ^Store, key: Key, session: ^Session) {
	owned := Key {
		sid     = strings.clone(key.sid, store.allocator),
		variant = strings.clone(key.variant, store.allocator),
	}
	session.touched = time.now()
	store.sessions[owned] = session
}

// The session for this browser and variant, creating one if there is none.
//
// Returns whether the session was REPLACED rather than found -- the cookie named something the store
// no longer has. The routes need that: a request against a replaced session is stale by definition,
// however well its question id happens to match, and is answered with a full resync.
store_get_or_create :: proc(
	store: ^Store,
	sid: string,
	system: ^corpus.System,
	settings: Settings,
) -> (
	session: ^Session,
	replaced: bool,
) {
	key := Key {
		sid     = sid,
		variant = system.key,
	}
	if found, ok := store_get(store, key); ok {
		return found, false
	}
	created := make_session(strings.clone(sid, store.allocator), system, settings, store.allocator)
	store_put(store, key, created)
	return created, true
}

store_count :: proc(store: ^Store) -> int {
	return len(store.sessions)
}

// Drop sessions nobody has touched for `TTL`.
//
// Lazily, on a request, rather than on a timer: there is nothing to sweep when nobody is playing,
// and a timer would keep a shard awake to find that out.
sweep_if_due :: proc(store: ^Store) {
	now := time.now()
	if time.diff(store.last_sweep, now) < SWEEP_INTERVAL {
		return
	}
	store.last_sweep = now
	for key, session in store.sessions {
		if time.diff(session.touched, now) > TTL {
			delete_key(&store.sessions, key)
		}
	}
}

// A new browser identity: `uuid4().hex` in the python, and the same 32 hex characters here.
//
// It identifies a browser, nothing more -- it is not a credential and nothing is authorised by it,
// which is why an unguessable-but-not-secret random value is the right shape.
new_sid :: proc(allocator := context.allocator) -> string {
	hex := "0123456789abcdef"
	buffer := make([]u8, 32, allocator)
	for index in 0 ..< len(buffer) {
		buffer[index] = hex[rand.int_max(16)]
	}
	return string(buffer)
}

// Whether a cookie value could be one of ours. Length and alphabet only: a session id is looked up,
// never trusted, so this is about not using an arbitrary header as a map key rather than about
// security.
valid_sid :: proc(sid: string) -> bool {
	if len(sid) != 32 {
		return false
	}
	for index in 0 ..< len(sid) {
		ch := sid[index]
		is_hex := (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f')
		if !is_hex {
			return false
		}
	}
	return true
}
