// The naming transform, pinned against the python.
//
// `testdata/topic_names.json` maps every real topic name to the slug and signal key the python
// produces. It is the one transform in this app that is silent when wrong -- a mistyped signal name
// binds a different signal rather than failing -- and four implementations of it exist, so a golden
// is the cheapest way to keep them in step.
package render

import "../corpus"
import "core:encoding/json"
import "core:testing"

@(private = "file")
TOPIC_NAMES_JSON :: #load("../testdata/topic_names.json", string)

@(private = "file")
Golden_Name :: struct {
	slug: string,
	key:  string,
}

@(test)
test_topic_signal_names_match_the_python :: proc(t: ^testing.T) {
	goldens: map[string]Golden_Name
	error := json.unmarshal(transmute([]u8)TOPIC_NAMES_JSON, &goldens, .JSON, context.temp_allocator)
	testing.expectf(t, error == nil, "the goldens did not parse: %v", error)
	if error != nil {
		return
	}
	testing.expect(t, len(goldens) > 0, "the goldens are empty")

	for name, wanted in goldens {
		slug := topic_slug(name, context.temp_allocator)
		key := topic_signal_key(name, context.temp_allocator)
		testing.expectf(t, slug == wanted.slug, "%q slugs to %q, python said %q", name, slug, wanted.slug)
		testing.expectf(t, key == wanted.key, "%q keys to %q, python said %q", name, key, wanted.key)
	}
}

// Every topic name in the corpus has to survive the trip, whether or not it is in the goldens --
// the goldens were captured once, and the notes move.
@(test)
test_every_corpus_topic_name_produces_a_usable_key :: proc(t: ^testing.T) {
	loaded, ok := corpus.load(context.temp_allocator)
	testing.expect(t, ok)
	if !ok {
		return
	}
	for &system in loaded.systems {
		for topic in system.topics.list {
			slug := topic_slug(topic.name, context.temp_allocator)
			key := topic_signal_key(topic.name, context.temp_allocator)
			testing.expectf(t, slug != "", "%q produced an empty slug", topic.name)
			testing.expectf(t, key != "", "%q produced an empty signal key", topic.name)
			// A key that starts with an underscore would be read as a server-owned signal and
			// never uploaded, which would silently un-tick the topic.
			testing.expectf(t, key[0] != '_', "%q produced an underscore key %q", topic.name, key)
		}
	}
}

// The five cases the python's own test parametrises, including the one that surprises everybody.
@(test)
test_the_kebab_transform_case_by_case :: proc(t: ^testing.T) {
	Case :: struct {
		input, kebab, camel: string,
	}
	cases := []Case {
		{"filterText", "filter-text", "filterText"},
		{"long auctions", "long-auctions", "longAuctions"},
		// a digit boundary splits, so a leading `1c` becomes `1-c` and camels to `1C`
		{"1c_opening", "1-c-opening", "1COpening"},
		// the underscore is a SEPARATOR, so a local signal written as a key is promoted
		{"_answering", "-answering", "Answering"},
		{"targetPct", "target-pct", "targetPct"},
	}
	for test_case in cases {
		kebab := datastar_kebab(test_case.input, context.temp_allocator)
		camel := datastar_camel(test_case.input, context.temp_allocator)
		testing.expectf(
			t,
			kebab == test_case.kebab,
			"kebab(%q) = %q, wanted %q",
			test_case.input,
			kebab,
			test_case.kebab,
		)
		testing.expectf(
			t,
			camel == test_case.camel,
			"camel(%q) = %q, wanted %q",
			test_case.input,
			camel,
			test_case.camel,
		)
	}
}

@(test)
test_punctuation_is_dropped_from_a_slug :: proc(t: ^testing.T) {
	// `2/1 game force` is a real topic name, and the slash is not a character a slug can carry
	testing.expect_value(t, topic_slug("2/1 game force", context.temp_allocator), "2-1-game-force")
	testing.expect_value(t, topic_signal_key("2/1 game force", context.temp_allocator), "21GameForce")

	// a name with nothing usable in it still has to produce a binding
	testing.expect_value(t, topic_slug("///", context.temp_allocator), "topic")
}
