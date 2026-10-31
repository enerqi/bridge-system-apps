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
//
// The candidates have distinct descriptions AND distinct auctions: an ambiguous auction has several
// right answers, so `(1C)--1N` drawn twice put two of its meanings among the choices for one auction
// (or the same auction twice among the auctions), and only one of them scored. A working set that
// runs out of distinct rows gives a question with fewer choices, and the answer is picked from the
// choices actually drawn.
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

	Pick :: struct {
		auction, description, auction_context: string,
	}
	picks := make([dynamic]Pick, 0, difficulty, context.temp_allocator)
	for _ in 0 ..< difficulty {
		found := false
		for _ in 0 ..< MAX_DRAWS {
			picked := auctions[working_set[rand.int_max(len(working_set))]]
			pretty := prettify_description(picked.description, context.temp_allocator)
			// Some auction sequences -- preludes, mostly -- carry no description at all.
			if strings.trim_space(pretty) == "" {
				continue
			}
			auction := strings.join(picked.sequence, AUCTION_SEPARATOR, context.temp_allocator)
			if picked_already(picks[:], auction, pretty) {
				continue
			}
			append(&picks, Pick{auction, pretty, picked.section})
			found = true
			break
		}
		if !found {
			break
		}
	}
	if len(picks) == 0 {
		return question
	}

	answer := picks[rand.int_max(len(picks))]
	candidates := make([]string, len(picks), allocator)
	contexts := make([]string, len(picks), allocator)
	for pick, index in picks {
		switch choice_type {
		case .Auctions:
			candidates[index] = strings.clone(pick.auction, allocator)
			contexts[index] = pick.auction_context
		case .Descriptions, .None:
			candidates[index] = strings.clone(pick.description, allocator)
		}
	}
	switch choice_type {
	case .Auctions:
		question.answer = strings.clone(answer.description, allocator)
		question.answer_candidate = strings.clone(answer.auction, allocator)
	case .Descriptions:
		question.answer = strings.clone(answer.auction, allocator)
		question.answer_candidate = strings.clone(answer.description, allocator)
		question.answer_context = answer.auction_context
	case .None:
	}
	question.candidates = candidates
	question.candidate_contexts = contexts
	return question
}

@(private = "file")
picked_already :: proc(picks: []$T, auction, description: string) -> bool {
	for pick in picks {
		if pick.auction == auction || pick.description == description {
			return true
		}
	}
	return false
}
