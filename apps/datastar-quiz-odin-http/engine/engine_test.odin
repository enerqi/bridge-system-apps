// The rules, case by case. Every constant here is parity-critical: the python, the Go port and this
// one have to award the same points for the same answer, or the comparison is measuring two
// different games.
package engine

import "../corpus"
import "core:testing"

@(test)
test_the_clock_matches_the_panel_table :: proc(t: ^testing.T) {
	// difficulty * seconds-per-level: 32, 35, 36, 35, 32. It peaks in the middle, which looks like
	// a mistake and is not -- the panel app's own table does this.
	testing.expect_value(t, seconds_for_difficulty(4), 32.0)
	testing.expect_value(t, seconds_for_difficulty(5), 35.0)
	testing.expect_value(t, seconds_for_difficulty(6), 36.0)
	testing.expect_value(t, seconds_for_difficulty(7), 35.0)
	testing.expect_value(t, seconds_for_difficulty(8), 32.0)
}

@(test)
test_difficulty_is_clamped_to_the_playable_range :: proc(t: ^testing.T) {
	testing.expect_value(t, clamp_difficulty(0), MIN_DIFFICULTY)
	testing.expect_value(t, clamp_difficulty(3), MIN_DIFFICULTY)
	testing.expect_value(t, clamp_difficulty(4), 4)
	testing.expect_value(t, clamp_difficulty(8), 8)
	testing.expect_value(t, clamp_difficulty(99), MAX_DIFFICULTY)
}

// python's `round()` is half to EVEN. The two disagree at every .5, and the percentages in this app
// land on one often enough for it to show.
@(test)
test_rounding_goes_half_to_even_like_python :: proc(t: ^testing.T) {
	testing.expect_value(t, py_round(0.5), 0)
	testing.expect_value(t, py_round(1.5), 2)
	testing.expect_value(t, py_round(2.5), 2)
	testing.expect_value(t, py_round(3.5), 4)
	testing.expect_value(t, py_round(-0.5), 0)
	testing.expect_value(t, py_round(-1.5), -2)
	testing.expect_value(t, py_round(-2.5), -2)

	// away from the halves it is ordinary rounding
	testing.expect_value(t, py_round(0.4), 0)
	testing.expect_value(t, py_round(0.6), 1)
	testing.expect_value(t, py_round(12.5), 12)
}

@(test)
test_the_time_bonus_is_the_fraction_of_the_clock_left :: proc(t: ^testing.T) {
	testing.expect_value(t, percent_time_left(0, 32), 100)
	testing.expect_value(t, percent_time_left(16, 32), 50)
	testing.expect_value(t, percent_time_left(32, 32), 0)
	// past the allowance it floors at zero rather than going negative
	testing.expect_value(t, percent_time_left(99, 32), 0)
	// a zero allowance cannot be divided by
	testing.expect_value(t, percent_time_left(1, 0), 0)
}

@(private = "file")
question_of :: proc(candidates: ..string) -> Question {
	return Question{candidates = candidates, answer_candidate = candidates[0]}
}

// Longer auctions are worth more: the base is the word count across every candidate, with the
// arrows removed rather than counted.
@(test)
test_the_base_score_counts_words_across_every_candidate :: proc(t: ^testing.T) {
	points := score_points(question_of("1C --> 1H", "1D --> 1S"), 0, 0)
	testing.expect_value(t, points.from_candidate_lengths, 4)
	testing.expect_value(t, points.from_streak_bonus, 0)
	testing.expect_value(t, points.from_time_bonus, 0)
	testing.expect_value(t, points_total(points), 4)
}

@(test)
test_the_streak_bonus_starts_at_two_and_caps_at_double :: proc(t: ^testing.T) {
	question := question_of("1C --> 1H", "1D --> 1S") // base 4

	// a streak of one is not a streak
	testing.expect_value(t, score_points(question, 1, 0).from_streak_bonus, 0)
	// 4 * 0.2
	testing.expect_value(t, score_points(question, 2, 0).from_streak_bonus, 1)
	// 4 * 0.5
	testing.expect_value(t, score_points(question, 5, 0).from_streak_bonus, 2)
	// the multiplier caps at 1.0, so the bonus never exceeds the base
	testing.expect_value(t, score_points(question, 10, 0).from_streak_bonus, 4)
	testing.expect_value(t, score_points(question, 50, 0).from_streak_bonus, 4)
}

@(test)
test_the_time_bonus_scales_the_base :: proc(t: ^testing.T) {
	question := question_of("1C --> 1H", "1D --> 1S") // base 4
	testing.expect_value(t, score_points(question, 0, 100).from_time_bonus, 4)
	testing.expect_value(t, score_points(question, 0, 50).from_time_bonus, 2)
	testing.expect_value(t, score_points(question, 0, 0).from_time_bonus, 0)
}

@(private = "file")
input_for :: proc(question: Question, candidate: string) -> Answer_Input {
	return Answer_Input{question = question, candidate = candidate, points_goal = POINTS_GOAL, target_pct = 70}
}

@(test)
test_a_right_answer_scores_and_extends_the_streak :: proc(t: ^testing.T) {
	score := make_score(context.temp_allocator)
	question := question_of("1C --> 1H", "1D --> 1S")

	result, last := answer(&score, input_for(question, "1C --> 1H"), context.temp_allocator)
	testing.expect(t, result.correct)
	testing.expect_value(t, score.streak, 1)
	testing.expect_value(t, score.questions_correct, 1)
	testing.expect_value(t, score.questions_attempted, 1)
	testing.expect_value(t, score.total_points, 4)
	testing.expect_value(t, last, 4)

	// "Correct!", "+4!", and the trailing one-second beat
	testing.expect_value(t, len(result.toasts), 3)
	testing.expect_value(t, result.toasts[0].text, "Correct!")
	testing.expect_value(t, result.toasts[1].text, "+4!")
	testing.expect_value(t, result.toasts[1].points_after, 4)
	testing.expect_value(t, result.toasts[len(result.toasts) - 1].pause, 1.0)
}

@(test)
test_a_wrong_answer_breaks_the_streak_and_says_little :: proc(t: ^testing.T) {
	score := make_score(context.temp_allocator)
	score.streak = 5
	question := question_of("1C --> 1H", "1D --> 1S")

	result, _ := answer(&score, input_for(question, "1D --> 1S"), context.temp_allocator)
	testing.expect(t, !result.correct)
	testing.expect_value(t, score.streak, 0)
	testing.expect_value(t, score.questions_attempted, 1)
	testing.expect_value(t, score.questions_correct, 0)

	// The answer is revealed in the card, not spelled out in a notification the player waits behind.
	testing.expect_value(t, len(result.toasts), 1)
	testing.expect_value(t, result.toasts[0].text, "Not quite")
	testing.expect_value(t, result.toasts[0].kind, "warning")
}

// Ladder mode takes back what the last right answer paid, floored at zero.
@(test)
test_ladder_mode_takes_back_the_last_award :: proc(t: ^testing.T) {
	score := make_score(context.temp_allocator)
	score.total_points = 100
	question := question_of("1C --> 1H", "1D --> 1S")

	input := input_for(question, "1D --> 1S")
	input.ladder_mode = true
	input.last_correct_points = 30
	result, last := answer(&score, input, context.temp_allocator)

	testing.expect_value(t, score.total_points, 70)
	testing.expect_value(t, last, 30) // unchanged by a wrong answer
	testing.expect_value(t, len(result.toasts), 2)
	testing.expect_value(t, result.toasts[1].text, "Ladder mode: -30 points")
	testing.expect_value(t, result.toasts[1].points_after, 70)
}

@(test)
test_ladder_mode_floors_at_zero_and_stays_quiet_there :: proc(t: ^testing.T) {
	score := make_score(context.temp_allocator)
	score.total_points = 10
	question := question_of("1C --> 1H", "1D --> 1S")

	input := input_for(question, "1D --> 1S")
	input.ladder_mode = true
	input.last_correct_points = 50
	result, _ := answer(&score, input, context.temp_allocator)
	testing.expect_value(t, score.total_points, 0)
	testing.expect_value(t, len(result.toasts), 2)

	// at zero already, there is nothing to take back and nothing to say about it
	result2, _ := answer(&score, input, context.temp_allocator)
	testing.expect_value(t, score.total_points, 0)
	testing.expect_value(t, len(result2.toasts), 1)
}

// The milestones are popped from the BACK of a reversed list, so they are collected in ascending
// order as the points pass them -- and several can fall to one answer.
@(test)
test_milestones_pay_for_skips_as_the_points_pass_them :: proc(t: ^testing.T) {
	score := make_score(context.temp_allocator)
	testing.expect_value(t, len(score.available_milestones), 6)
	// reversed: the last element is the lowest, and it is the one popped first
	testing.expect_value(t, score.available_milestones[5], 0.1)
	testing.expect_value(t, score.available_milestones[0], 1.0)

	// The answer is worth 4 (two candidates, two words each, no streak or time bonus), so starting
	// at 246 lands exactly on the 25% milestone and crosses the 10% one on the way.
	question := question_of("1C --> 1H", "1D --> 1S")
	score.total_points = 246

	input := input_for(question, "1C --> 1H")
	result, _ := answer(&score, input, context.temp_allocator)

	// crossing 100 and 250 at once awards two skips
	testing.expect_value(t, result.awarded_skips, 2)
	testing.expect_value(t, len(score.available_milestones), 4)

	awarding := 0
	for toast in result.toasts {
		if toast.awards_skip {
			awarding += 1
			testing.expect_value(t, toast.text, "+1 SKIP!")
		}
	}
	testing.expect_value(t, awarding, 2)
}

@(test)
test_reaching_the_goal_completes_the_quiz :: proc(t: ^testing.T) {
	score := make_score(context.temp_allocator)
	score.total_points = 999
	question := question_of("1C --> 1H", "1D --> 1S")

	result, _ := answer(&score, input_for(question, "1C --> 1H"), context.temp_allocator)
	testing.expect(t, result.completed)
}

// With a target on, reaching the goal is not enough -- the accuracy has to clear the bar too, and
// the player is told where they stand rather than silently not finishing.
@(test)
test_the_target_gate_holds_the_quiz_open :: proc(t: ^testing.T) {
	score := make_score(context.temp_allocator)
	score.total_points = 999
	score.questions_attempted = 9
	score.questions_correct = 3
	question := question_of("1C --> 1H", "1D --> 1S")

	input := input_for(question, "1C --> 1H")
	input.target_on = true
	input.target_pct = 70
	result, _ := answer(&score, input, context.temp_allocator)

	testing.expect(t, !result.completed)
	found := false
	for toast in result.toasts {
		if toast.kind == "warning" {
			found = true
			testing.expect_value(t, toast.text, "Current score 40%, target score 70%")
		}
	}
	testing.expect(t, found, "the player should be told why the quiz did not finish")
}

// A per-session goal, not the module constant: the debug panel shortens a quiz without a global
// mutation, and two sessions in one process may disagree about where the milestones fall.
@(test)
test_the_goal_is_per_session :: proc(t: ^testing.T) {
	score := make_score(context.temp_allocator)
	score.total_points = 9
	question := question_of("1C --> 1H", "1D --> 1S")

	input := input_for(question, "1C --> 1H")
	input.points_goal = 10
	result, _ := answer(&score, input, context.temp_allocator)
	testing.expect(t, result.completed, "13 points should finish a quiz whose goal is 10")
}

@(test)
test_the_score_percentage_rounds_like_python :: proc(t: ^testing.T) {
	score := make_score(context.temp_allocator)
	testing.expect_value(t, score_percentage(score), 0) // no attempts, no division

	score.questions_attempted = 3
	score.questions_correct = 2
	testing.expect_value(t, score_percentage(score), 67)

	score.questions_attempted = 8
	score.questions_correct = 1
	testing.expect_value(t, score_percentage(score), 12) // 12.5, half to even
}

@(test)
test_suit_shorthand_is_spelled_out_for_display :: proc(t: ^testing.T) {
	testing.expect_value(t, prettify_description("  2+ !cs  ", context.temp_allocator), "2+ Cs")
	testing.expect_value(t, prettify_description("!h and !s", context.temp_allocator), "H and S")
	// a bang that is not shorthand is left alone
	testing.expect_value(t, prettify_description("wow!", context.temp_allocator), "wow!")
	// no bang at all, no allocation and no change
	testing.expect_value(t, prettify_description(" plain ", context.temp_allocator), "plain")
}

//
// Question generation
//

// A package-level table rather than a compound literal returned from a proc: a slice literal built
// in a call frame points at that frame's stack.
@(private = "file")
SAMPLE_AUCTIONS := [10]corpus.Auction {
	{sequence = []string{"1C"}, description = "strong, 16+"},
	{sequence = []string{"1D"}, description = "a diamond opening"},
	{sequence = []string{"1H"}, description = "five hearts"},
	{sequence = []string{"1S"}, description = "five spades"},
	{sequence = []string{"1N"}, description = "balanced"},
	{sequence = []string{"2C"}, description = "game force"},
	{sequence = []string{"2D"}, description = "weak two"},
	{sequence = []string{"2H"}, description = "weak two in hearts"},
	{sequence = []string{"2S"}, description = "weak two in spades"},
	// no description: never picked as a candidate
	{sequence = []string{"3C"}, description = "   "},
}

@(private = "file")
sample_auctions :: proc() -> []corpus.Auction {
	return SAMPLE_AUCTIONS[:]
}

@(test)
test_a_question_has_one_candidate_per_difficulty :: proc(t: ^testing.T) {
	auctions := sample_auctions()
	working := []u32{0, 1, 2, 3, 4, 5, 6, 7, 8, 9}

	for difficulty in MIN_DIFFICULTY ..= MAX_DIFFICULTY {
		question := new_question_of_type(auctions, working, difficulty, .Auctions, context.temp_allocator)
		testing.expectf(
			t,
			len(question.candidates) == difficulty,
			"difficulty %d produced %d candidates",
			difficulty,
			len(question.candidates),
		)
		index, found := answer_index(question)
		testing.expect(t, found, "the answer must be among the candidates")
		testing.expect(t, index >= 0 && index < len(question.candidates))
	}
}

@(test)
test_the_two_question_shapes_ask_opposite_ways :: proc(t: ^testing.T) {
	auctions := sample_auctions()
	working := []u32{0, 1, 2, 3, 4, 5, 6, 7, 8}

	// candidates are auctions, the prompt is the description that fits one of them
	as_auctions := new_question_of_type(auctions, working, 4, .Auctions, context.temp_allocator)
	testing.expect_value(t, as_auctions.choice_type, Choice_Type.Auctions)
	index, _ := answer_index(as_auctions)
	testing.expect_value(t, as_auctions.candidates[index], as_auctions.answer_candidate)

	// and the other way round
	as_descriptions := new_question_of_type(auctions, working, 4, .Descriptions, context.temp_allocator)
	testing.expect_value(t, as_descriptions.choice_type, Choice_Type.Descriptions)
}

@(test)
test_candidates_are_distinct :: proc(t: ^testing.T) {
	auctions := sample_auctions()
	working := []u32{0, 1, 2, 3, 4, 5, 6, 7, 8}
	question := new_question_of_type(auctions, working, 8, .Descriptions, context.temp_allocator)
	for candidate, index in question.candidates {
		for other in question.candidates[index + 1:] {
			testing.expectf(t, candidate != other, "%q appears twice", candidate)
		}
	}
}

@(test)
test_an_empty_working_set_produces_no_candidates :: proc(t: ^testing.T) {
	auctions := sample_auctions()
	question := new_question_of_type(auctions, {}, 5, .Auctions, context.temp_allocator)
	testing.expect_value(t, len(question.candidates), 0)
}
