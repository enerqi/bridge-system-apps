// The bidding corpus: the auctions a quiz asks about, and the filter over them.
//
// The corpus is NOT parsed from `.bml` here. `apps/datastar-quiz/tools/export_corpus.py` imports the
// python app's own loader -- which imports the external `bml` module and walks the parsed bid tables
// -- and writes one deterministic JSON file per variant. Those files are embedded below. It is the
// same decision the Go and Rust ports made, and `HANDOFF.md` §4 explains why: reimplementing the bml
// parser would be porting a different program, and the export is byte-stable, so a regeneration that
// changes the file is a real change to the notes.
//
// The MATCHER is not exported, though. That is `../bidfilter`, ported line by line, because it is
// where the CPU goes and a comparison that skipped it would not be a comparison. The python spends
// 15.8 ms on `check_filter("1C")` over 7,627 auctions and 4.25 s preparing a system at boot.
package corpus

import "../bidfilter"
import "core:encoding/json"
import "core:strings"

VARIANT_KEYS :: [2]string{"squad", "swedish"}
DEFAULT_VARIANT_KEY :: "squad"

@(private)
SQUAD_JSON :: #load("data/squad.json", string)
@(private)
SWEDISH_JSON :: #load("data/swedish.json", string)

// What the exporter writes. Field names match the JSON keys exactly, so no tags are needed.
@(private)
Exported_Auction :: struct {
	sequence:    []string,
	description: string,
}

@(private)
Exported_Topic :: struct {
	name:        string,
	patterns:    []string,
	description: string,
}

@(private)
Exported_System :: struct {
	variant:          string,
	title:            string,
	bml_file:         string,
	system_notes_url: string,
	auctions:         []Exported_Auction,
	topics:           []Exported_Topic,
}

// One auction and what it means, as the quiz shows it.
Auction :: struct {
	sequence:    []string,
	description: string,
}

// A quiz variant: one bml system, its auctions, its topic list, and the pre-parsed index the filter
// runs over.
System :: struct {
	key:              string,
	title:            string,
	bml_file:         string,
	system_notes_url: string,
	auctions:         []Auction,
	topics:           bidfilter.Topics,

	// The prepared auctions, index-aligned with `auctions`. Each entry is the concrete auctions that
	// written auction stands for -- usually one.
	prepared:         []bidfilter.Variants,

	// Every index, for the unfiltered case. Held once rather than rebuilt per request.
	all:              []u32,

	// Where anything the MEMO keeps has to come from: the corpus's own allocator, which lives as
	// long as the process. Never the caller's, and never `context.allocator` inside a handler --
	// Tina points that at the per-call scratch arena, so a memoised entry allocated there is
	// dangling by the next request. See `cache.odin`.
	allocator:        runtime_allocator,

	// Which slot of the per-shard memo belongs to this system. The memo is NOT a field here any
	// more: `System` is shared by every shard and a map is not, so each shard keeps its own,
	// indexed by this.
	cache_slot:       int,
}

Corpus :: struct {
	systems:   []System,
	allocator: runtime_allocator,
}

//
// Filter results
//

Status :: enum u8 {
	All, // no filter in force: the whole system
	Ok, // a filter that selected enough auctions to build questions from
	Error, // nothing in the text resolved to a pattern or a topic
	Too_Few, // it resolved, but selected fewer auctions than a question needs
}

status_text :: proc "contextless" (status: Status) -> string {
	switch status {
	case .All:
		return "all"
	case .Ok:
		return "ok"
	case .Error:
		return "error"
	case .Too_Few:
		return "too_few"
	}
	return "all"
}

Filter_Check :: struct {
	status: Status,
	hits:   []u32,
	parsed: bidfilter.Parsed_Filter,
}

filter_usable :: proc "contextless" (check: Filter_Check) -> bool {
	return check.status == .Ok
}

//
// Loading
//

load :: proc(allocator := context.allocator) -> (corpus: Corpus, ok: bool) {
	sources := [2]string{SQUAD_JSON, SWEDISH_JSON}
	keys := VARIANT_KEYS

	if len(sources) > MAX_SYSTEMS {
		return {}, false
	}
	systems := make([]System, len(sources), allocator)
	for source, index in sources {
		system, system_ok := load_system(source, allocator)
		if !system_ok {
			return {}, false
		}
		if system.key != keys[index] {
			return {}, false
		}
		// The slot each shard's memo for this system lives in. Assigned here, once, because it is a
		// property of the corpus rather than of any shard.
		system.cache_slot = index
		systems[index] = system
	}
	return Corpus{systems = systems, allocator = allocator}, true
}

@(private = "file")
load_system :: proc(source: string, allocator: runtime_allocator) -> (system: System, ok: bool) {
	exported: Exported_System
	if error := json.unmarshal(transmute([]u8)source, &exported, .JSON, allocator); error != nil {
		return {}, false
	}

	auctions := make([]Auction, len(exported.auctions), allocator)
	sequences := make([][]string, len(exported.auctions), context.temp_allocator)
	for entry, index in exported.auctions {
		auctions[index] = Auction {
			sequence    = entry.sequence,
			description = entry.description,
		}
		sequences[index] = entry.sequence
	}

	topic_list := make([]bidfilter.Topic, len(exported.topics), context.temp_allocator)
	for entry, index in exported.topics {
		topic_list[index] = bidfilter.Topic {
			name        = entry.name,
			patterns    = entry.patterns,
			description = entry.description,
		}
	}

	all := make([]u32, len(auctions), allocator)
	for index in 0 ..< len(auctions) {
		all[index] = u32(index)
	}

	return System {
			key = exported.variant,
			title = exported.title,
			bml_file = exported.bml_file,
			system_notes_url = exported.system_notes_url,
			auctions = auctions,
			topics = bidfilter.make_topics(topic_list, allocator),
			prepared = bidfilter.prepare_sequence_bids(sequences, allocator),
			all = all,
			allocator = allocator,
		},
		true
}

system_for :: proc(corpus: Corpus, key: string) -> (system: ^System, ok: bool) {
	for &candidate in corpus.systems {
		if candidate.key == key {
			return &candidate, true
		}
	}
	return nil, false
}

default_system :: proc(corpus: Corpus) -> ^System {
	system, _ := system_for(corpus, DEFAULT_VARIANT_KEY)
	return system
}

//
// Filtering
//

// Which auctions a filter selects, and whether there are enough of them to build questions from.
//
// An empty or unresolvable filter selects the whole system -- question generation needs `min_hits`
// distinct auctions to build the hardest question.
//
// MEMOISED, because this is the app's most expensive routine and it runs on every keystroke. The KEY
// is the NORMALISED text, which costs nothing extra and is exact rather than approximate. Case is
// deliberately NOT folded on top of that: `m` is the minors and `M` the majors, so a
// case-insensitive key would answer `1m` with the majors.
//
// No lock, unlike the Go and Rust ports -- but for a different reason now that the shard count is a
// setting: the memo is PER SHARD (`cache.odin`), so there is no shared structure to exclude anybody
// from. What is shared is the `System` itself, which nothing here writes.
//
// It takes NO allocator, deliberately. Everything the memo keeps -- the key's bytes and the
// `Filter_Check` itself -- outlives the call that produced it and therefore comes from
// `system.allocator`. A caller's allocator would be wrong in the one way that matters: inside a Tina
// handler `context.allocator` IS the per-call scratch arena, so passing it memoised a pointer into
// memory the next request overwrites.
check_filter :: proc(system: ^System, text: string, min_hits: int) -> ^Filter_Check {
	cache := shard_cache(system)
	key := bidfilter.normalize_filter_text(text, context.temp_allocator)
	if found, ok := cache_get(cache, key, min_hits); ok {
		return found
	}
	check := check_uncached(system, key, min_hits, system.allocator)
	cache_put(cache, key, min_hits, check, system.allocator)
	return check
}

@(private = "file")
check_uncached :: proc(
	system: ^System,
	normalised: string,
	min_hits: int,
	allocator: runtime_allocator,
) -> ^Filter_Check {
	check := new(Filter_Check, allocator)
	check.parsed = bidfilter.parse_filter(normalised, system.topics, allocator)

	if len(check.parsed.patterns) == 0 {
		check.status = len(check.parsed.errors) == 0 ? .All : .Error
		check.hits = system.all
		return check
	}

	hits := make([dynamic]u32, 0, len(system.auctions) / 4, allocator)
	for index in 0 ..< len(system.auctions) {
		if bidfilter.bids_match_any(system.prepared[index][:], check.parsed.patterns) {
			append(&hits, u32(index))
		}
	}
	check.hits = hits[:]
	check.status = len(check.hits) < min_hits ? .Too_Few : .Ok
	return check
}

//
// Variant selection from a query string
//
// Both of these scan the WHOLE query for a variant key, which is how the python does it -- and it
// carries a known consequence, kept on purpose: datastar sends signals as `?datastar=<json>` on a
// GET, so typing "swedish" into the FILTER BOX of a squad page switches systems on the next
// `/filter/preview`. The Go port reproduces this rather than fixing it, on the grounds that a
// divergence would show up in the load runs and be read as a runtime effect. So does this one.
//

// An explicit `?swedish` / `?squad` and nothing else.
requested_variant :: proc(corpus: Corpus, query: string) -> (system: ^System, ok: bool) {
	keys := VARIANT_KEYS
	for key in keys {
		if strings.contains(query, key) {
			return system_for(corpus, key)
		}
	}
	return nil, false
}

// As `requested_variant`, but a BARE url means "back to the default variant", while a non-empty
// query naming no variant (`?debug`) means "keep whatever you have". Only the index page uses this.
variant_switch_for_query :: proc(corpus: Corpus, query: string) -> (system: ^System, ok: bool) {
	if requested, found := requested_variant(corpus, query); found {
		return requested, true
	}
	if strings.trim_space(query) == "" {
		return default_system(corpus), true
	}
	return nil, false
}
