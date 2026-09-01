// The parity gate.
//
// `apps/datastar-quiz/tools/export_filter_goldens.py` runs 41 hand-written probes -- one per token
// kind the pattern language has -- plus EVERY topic name of both variants, against the whole corpus
// at `min_hits = 8` (engine.MAX_DIFFICULTY), and records what the python's own matcher selected.
// 132 probes in all, 59 squad and 73 swedish.
//
// Each probe pins five things, and the digest is the one that matters: a sha256 over the
// comma-joined indices of the selected auctions, so a single auction moving in or out of a result
// fails. A hit COUNT alone would not -- two different auctions swapping in and out keeps the count.
//
// The same file, byte-identical, is what the Go and Rust ports check against.
package corpus

import "../bidfilter"
import "core:crypto/hash"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
GOLDENS_JSON :: #load("../testdata/filter_goldens.json", string)

@(private = "file")
Golden :: struct {
	text:        string,
	min_hits:    int,
	status:      string,
	hits:        int,
	digest:      string,
	canonical:   string,
	errors:      []string,
	topic_names: []string,
}

@(test)
test_the_filter_agrees_with_the_python :: proc(t: ^testing.T) {
	loaded, ok := load(context.allocator)
	testing.expect(t, ok, "the embedded corpus did not load")
	if !ok {
		return
	}

	goldens: map[string][]Golden
	error := json.unmarshal(transmute([]u8)GOLDENS_JSON, &goldens, .JSON, context.allocator)
	testing.expectf(t, error == nil, "the goldens did not parse: %v", error)
	if error != nil {
		return
	}

	checked := 0
	for variant_key, probes in goldens {
		system, found := system_for(loaded, variant_key)
		testing.expectf(t, found, "the goldens name a variant the corpus does not have: %q", variant_key)
		if !found {
			continue
		}
		for probe in probes {
			check_probe(t, system, variant_key, probe)
			checked += 1
		}
	}

	// The count is asserted too: a goldens file that silently lost its probes would otherwise pass.
	testing.expect_value(t, checked, 132)
}

@(private = "file")
check_probe :: proc(t: ^testing.T, system: ^System, variant_key: string, probe: Golden) {
	check := check_filter(system, probe.text, probe.min_hits)

	probe_id := fmt.tprintf("%s %q", variant_key, probe.text)

	testing.expectf(
		t,
		status_text(check.status) == probe.status,
		"%s: status %q, python said %q",
		probe_id,
		status_text(check.status),
		probe.status,
	)
	testing.expectf(
		t,
		len(check.hits) == probe.hits,
		"%s: %d hits, python said %d",
		probe_id,
		len(check.hits),
		probe.hits,
	)
	if digest := hit_digest(check.hits); digest != probe.digest {
		testing.expectf(
			t,
			false,
			"%s: selected a different set of auctions (digest %s, python %s)",
			probe_id,
			digest,
			probe.digest,
		)
	}
	testing.expectf(
		t,
		check.parsed.canonical_text == probe.canonical,
		"%s: canonical %q, python said %q",
		probe_id,
		check.parsed.canonical_text,
		probe.canonical,
	)
	expect_same_strings(t, probe_id, "errors", check.parsed.errors, probe.errors)
	expect_same_strings(t, probe_id, "topic_names", check.parsed.topic_names, probe.topic_names)
}

// sha256 over the comma-joined indices, which is what the exporter hashes.
@(private = "file")
hit_digest :: proc(hits: []u32) -> string {
	joined := strings.builder_make(0, len(hits) * 5, context.temp_allocator)
	for index, position in hits {
		if position > 0 {
			strings.write_byte(&joined, ',')
		}
		strings.write_uint(&joined, uint(index))
	}
	sum: [32]u8
	hash.hash_string_to_buffer(.SHA256, strings.to_string(joined), sum[:])

	out := strings.builder_make(0, 64, context.temp_allocator)
	for octet in sum {
		fmt.sbprintf(&out, "%02x", octet)
	}
	return strings.to_string(out)
}

@(private = "file")
expect_same_strings :: proc(t: ^testing.T, probe_id, field: string, got, wanted: []string) {
	if len(got) != len(wanted) {
		testing.expectf(t, false, "%s: %s was %v, python said %v", probe_id, field, got, wanted)
		return
	}
	for value, index in got {
		if value != wanted[index] {
			testing.expectf(t, false, "%s: %s was %v, python said %v", probe_id, field, got, wanted)
			return
		}
	}
}

//
// The corpus itself
//

@(test)
test_the_corpus_loads_both_systems :: proc(t: ^testing.T) {
	loaded, ok := load(context.allocator)
	testing.expect(t, ok, "the embedded corpus did not load")
	if !ok {
		return
	}

	squad, has_squad := system_for(loaded, "squad")
	testing.expect(t, has_squad)
	testing.expect_value(t, squad.title, "U16 Squad System Quiz")
	testing.expect_value(t, squad.bml_file, "squad-system.bml")
	testing.expect_value(t, len(squad.auctions), 1652)

	swedish, has_swedish := system_for(loaded, "swedish")
	testing.expect(t, has_swedish)
	testing.expect_value(t, swedish.bml_file, "bidding-system.bml")

	// Every auction has a prepared entry, index-aligned. The filter indexes one by the other, so a
	// mismatch would be an out-of-bounds read on the first keystroke rather than a wrong answer.
	testing.expect_value(t, len(squad.prepared), len(squad.auctions))
	testing.expect_value(t, len(swedish.prepared), len(swedish.auctions))

	testing.expect(t, bidfilter.topic_count(squad.topics) > 0, "squad has no topics")
	testing.expect(t, bidfilter.topic_count(swedish.topics) > 0, "swedish has no topics")
}

// The memo is what makes the filter box usable: the python measures an 87.6% hit rate under load,
// because a keystroke re-checks text that is mostly the same as the last one.
@(test)
test_the_filter_memo_answers_the_second_call :: proc(t: ^testing.T) {
	loaded, ok := load(context.allocator)
	testing.expect(t, ok)
	if !ok {
		return
	}
	system, _ := system_for(loaded, "squad")
	clear_filter_cache(filter_cache_for(system))

	first := check_filter(system, "1C", 8)
	second := check_filter(system, "1C", 8)
	testing.expect(t, first == second, "the second check should be the memoised pointer")

	info := filter_cache_info(filter_cache_for(system)^)
	testing.expect_value(t, info.hits, 1)
	testing.expect_value(t, info.misses, 1)

	// The KEY is the normalised text, so spelling the same filter differently still hits.
	_ = check_filter(system, "  1c  ", 8)
	testing.expect_value(t, filter_cache_info(filter_cache_for(system)^).misses, 2)
	_ = check_filter(system, "1C ", 8)
	testing.expect_value(t, filter_cache_info(filter_cache_for(system)^).hits, 2)
}

// Case is NOT folded into the memo key, and this is the reason: `m` is the minors and `M` the
// majors, so a case-insensitive key would answer `1m` with the majors' auctions.
@(test)
test_the_memo_key_keeps_minors_apart_from_majors :: proc(t: ^testing.T) {
	loaded, ok := load(context.allocator)
	testing.expect(t, ok)
	if !ok {
		return
	}
	system, _ := system_for(loaded, "squad")

	minors := check_filter(system, "1m", 8)
	majors := check_filter(system, "1M", 8)
	testing.expect(t, minors != majors, "1m and 1M must not share a memo entry")
}

_ :: time
