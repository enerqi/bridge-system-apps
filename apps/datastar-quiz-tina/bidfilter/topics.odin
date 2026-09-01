// Topics -- pre-composed bundles of patterns -- and whole-filter parsing.
package bidfilter

import "core:strings"

// A named bundle of patterns; an auction matches the topic if it matches any one of them.
//
// The python reads these from a per-variant toml beside `apps/quiz/bidfilter.py` (whole-file
// replacement, no merging). Here they arrive with the exported corpus, already filtered to the bml
// system they apply to and already in file order -- which is the order the picker renders them in.
Topic :: struct {
	name:        string,
	patterns:    []string,
	description: string,
}

// A variant's topic list, in file order, with the parsed patterns alongside.
//
// Parsing happens once at load: a topic whose patterns do not parse is dropped rather than breaking
// the whole list, exactly as the python's `load_topics` does.
Topics :: struct {
	list:       [dynamic]Topic,
	// parsed patterns per topic, index-aligned with `list`
	parsed:     [dynamic][]Pattern,
	// normalised name per topic, index-aligned -- searched in file order, so a fuzzy match is
	// deterministic
	normalised: [dynamic]string,
}

make_topics :: proc(list: []Topic, allocator := context.allocator) -> Topics {
	topics := Topics {
		list       = make([dynamic]Topic, 0, len(list), allocator),
		parsed     = make([dynamic][]Pattern, 0, len(list), allocator),
		normalised = make([dynamic]string, 0, len(list), allocator),
	}
	for topic in list {
		if len(topic.patterns) == 0 {
			continue
		}
		parsed := make([dynamic]Pattern, 0, len(topic.patterns), allocator)
		ok := true
		for text in topic.patterns {
			pattern, parsed_ok := parse_pattern(text, allocator)
			if !parsed_ok {
				ok = false
				break
			}
			append(&parsed, pattern)
		}
		if !ok {
			for &pattern in parsed {
				destroy_pattern(&pattern)
			}
			delete(parsed)
			continue
		}
		append(&topics.normalised, norm_name(topic.name, allocator))
		append(&topics.list, topic)
		append(&topics.parsed, parsed[:])
	}
	return topics
}

topic_count :: proc(topics: Topics) -> int {
	return len(topics.list)
}

// Resolve free-form text to a single topic index.
//
// Tried in order, each ignoring case and superfluous whitespace: the exact name, then -- unless
// `fuzzy` is off -- a unique prefix, then a unique substring. Ambiguous input resolves to nothing so
// the caller can fall back to treating it as a bid pattern.
match_topic_name :: proc(topics: Topics, text: string, fuzzy: bool) -> (index: int, ok: bool) {
	target := norm_name(text, context.temp_allocator)
	if target == "" {
		return 0, false
	}
	for name, position in topics.normalised {
		if name == target {
			return position, true
		}
	}
	if !fuzzy {
		return 0, false
	}
	// Prefix first, then substring: a unique prefix is the stronger claim.
	for test in 0 ..< 2 {
		hit, count := 0, 0
		for name, position in topics.normalised {
			matched := test == 0 ? strings.has_prefix(name, target) : strings.contains(name, target)
			if matched {
				hit = position
				count += 1
			}
		}
		if count == 1 {
			return hit, true
		}
	}
	return 0, false
}

// Fold a topic name for comparison the same way user input is normalised, so a name containing a
// dash still matches what the user typed.
@(private = "file")
norm_name :: proc(name: string, allocator := context.allocator) -> string {
	normalised := normalize_filter_text(name, context.temp_allocator)
	return strings.to_lower(normalised, allocator)
}

// The result of interpreting a filter string.
//
// `patterns` is the flat OR list actually matched against; `entries` records what each
// comma-separated entry was, and `canonical_text` is the input rewritten with resolved topic names
// -- what the input box shows after the user commits.
Parsed_Filter :: struct {
	patterns:       []Pattern,
	entries:        []string,
	topic_names:    []string,
	canonical_text: string,
	errors:         []string,
}

// Interpret a whole filter string: `topic name, 1D-1M, 1H-(X)`.
//
// Each entry is resolved in this order: an exact topic name, then a bid pattern, then a fuzzy topic
// name (unique prefix or substring -- this is what makes typing part of a topic and pressing Enter
// select it). Patterns are tried BEFORE the fuzzy step, so a valid pattern is never hijacked by a
// topic that happens to contain it in its name.
//
// Unresolvable entries land in `errors` and are skipped; the remaining entries still filter, so one
// typo does not discard the rest.
parse_filter :: proc(text: string, topics: Maybe(Topics), allocator := context.allocator) -> Parsed_Filter {
	entries := split_entries(text, allocator)
	patterns := make([dynamic]Pattern, 0, len(entries), allocator)
	topic_names := make([dynamic]string, 0, len(entries), allocator)
	errors := make([dynamic]string, 0, 0, allocator)
	canonical := strings.builder_make(0, len(text), allocator)

	for entry in entries {
		index, found := -1, false
		if list, has_topics := topics.?; has_topics {
			index, found = match_topic_name(list, entry, false)
		}
		if !found {
			if pattern, ok := parse_pattern(entry, allocator); ok {
				append(&patterns, pattern)
				write_separated(&canonical, canonical_pattern_text(entry, context.temp_allocator))
				continue
			}
			// fuzzy fallback, only once the entry has failed to be a pattern
			if list, has_topics := topics.?; has_topics {
				index, found = match_topic_name(list, entry, true)
			}
		}
		if !found {
			append(&errors, entry)
			continue
		}
		list := topics.? or_else Topics{}
		append(&patterns, ..list.parsed[index])
		write_separated(&canonical, list.list[index].name)
		append(&topic_names, list.list[index].name)
	}

	return Parsed_Filter {
		patterns = patterns[:],
		entries = entries,
		topic_names = topic_names[:],
		canonical_text = strings.to_string(canonical),
		errors = errors[:],
	}
}

@(private = "file")
write_separated :: proc(builder: ^strings.Builder, text: string) {
	if strings.builder_len(builder^) > 0 {
		strings.write_string(builder, ", ")
	}
	strings.write_string(builder, text)
}

// Pre-parse a corpus of auctions once, so that repeatedly re-filtering it -- validating on every
// keystroke -- is only prefix comparisons.
prepare_sequence_bids :: proc(sequences: [][]string, allocator := context.allocator) -> []Variants {
	out := make([]Variants, len(sequences), allocator)
	for sequence, index in sequences {
		out[index] = prepare_auction(sequence, allocator)
	}
	return out
}
