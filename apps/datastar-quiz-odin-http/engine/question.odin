// Drawing a question from a working set.
package engine

import "../corpus"
import "core:math/rand"
import "core:strings"

// Draw one question from a working set: `quiz.generate_question`, with the choice type picked at
// random as `random_multi_choice_type` does.
//
// `working_set` is INDICES into `auctions`. An unfiltered session points at every one, and a
// filtered session points at the memo's own hit list, so nothing is copied to draw a question.
new_question :: proc(
	auctions: []corpus.Auction,
	working_set: []u32,
	difficulty: int,
	allocator := context.allocator,
) -> Question {
	choice_type := rand.float64() < 0.5 ? Choice_Type.Auctions : Choice_Type.Descriptions
	return new_question_of_type(auctions, working_set, difficulty, choice_type, allocator)
}

// `new_question` with the choice type named, for tests.
new_question_of_type :: proc(
	auctions: []corpus.Auction,
	working_set: []u32,
	difficulty: int,
	choice_type: Choice_Type,
	allocator := context.allocator,
) -> Question {
	question := Question {
		choice_type = choice_type,
	}
	if len(working_set) == 0 {
		return question
	}

	count := difficulty
	candidates := make([dynamic]string, 0, count, allocator)
	seen := make([dynamic]string, 0, count, context.temp_allocator)
	answer_at := rand.int_max(count)

	for index in 0 ..< count {
		description, auction: string
		for _ in 0 ..< MAX_DRAWS {
			picked := auctions[working_set[rand.int_max(len(working_set))]]
			pretty := prettify_description(picked.description, allocator)
			// Some auction sequences -- preludes, mostly -- carry no description at all.
			if strings.trim_space(pretty) == "" || contains_string(seen[:], pretty) {
				continue
			}
			auction = strings.join(picked.sequence, AUCTION_SEPARATOR, allocator)
			description = pretty
			break
		}
		if description == "" {
			break
		}
		append(&seen, description)

		switch choice_type {
		case .Auctions:
			if index == answer_at {
				question.answer = description
				question.answer_candidate = auction
			}
			append(&candidates, auction)
		case .Descriptions:
			if index == answer_at {
				question.answer = auction
				question.answer_candidate = description
			}
			append(&candidates, description)
		case .None:
		}
	}
	question.candidates = candidates[:]
	return question
}

@(private = "file")
contains_string :: proc(haystack: []string, needle: string) -> bool {
	for value in haystack {
		if value == needle {
			return true
		}
	}
	return false
}
