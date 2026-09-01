// The quiz rules: question generation, scoring, the time bonus, milestone skip awards, completion.
//
// No HTTP, no HTML, no signals -- this is the state machine the routes drive, ported from
// `apps/datastar-quiz/engine.py`, which is itself a port of the panel app's `points` /
// `on_answer_click`. Keeping it separate is what lets it be tested and benchmarked with no server in
// the way, and compared against the python's own microbenchmarks.
//
// Scoring applies the whole state change at once and RETURNS the instalments as `Toast`s: the SSE
// handler replays them with the same pauses, but a mid-stream reload sees final state rather than a
// half-scored session.
package engine

import "../corpus"
import "core:fmt"
import "core:math"
import "core:strings"

INITIAL_DIFFICULTY :: 5
MIN_DIFFICULTY :: 4
MAX_DIFFICULTY :: 8

POINTS_GOAL :: 1000
INITIAL_SKIPS :: 3

// The fractions of the goal that each pay for one skip.
SCORE_MILESTONES :: [6]f64{0.1, 0.25, 0.45, 0.65, 0.8, 1.0}

// Seconds allowed per question, by difficulty -- the panel's `reset_time_bonus_by_difficulty`.
@(private = "file")
seconds_per_level :: proc "contextless" (difficulty: int) -> int {
	switch difficulty {
	case 4:
		return 8
	case 5:
		return 7
	case 6:
		return 6
	case 7:
		return 5
	case 8:
		return 4
	}
	return 4
}

// The allowance for one question: 32, 35, 36, 35, 32 seconds for difficulties 4 to 8.
seconds_for_difficulty :: proc "contextless" (difficulty: int) -> f64 {
	return f64(difficulty) * f64(seconds_per_level(difficulty))
}

// python's `round()` on a float: half to EVEN, not half away from zero.
//
// Used everywhere the python rounds, because the two disagree at every .5 -- and the percentages
// here land on one often enough for it to show (a 50% time bonus on an even candidate count, the
// gauge at exactly 12.5%). The Go port carries the same helper for the same reason.
py_round :: proc "contextless" (value: f64) -> int {
	rounded := math.round(value)
	// `math.round` goes half AWAY from zero; pull the exact .5 cases back to even.
	if abs(value - math.trunc(value)) == 0.5 && math.mod(rounded, 2) != 0 {
		rounded -= math.sign(value)
	}
	return int(rounded)
}

// The time bonus percentage, as the panel's `TimeBonus` progress bar computed it.
percent_time_left :: proc "contextless" (elapsed, allowed: f64) -> int {
	if allowed <= 0 {
		return 0
	}
	return py_round(max(allowed - elapsed, 0) / allowed * 100)
}

clamp_difficulty :: proc "contextless" (value: int) -> int {
	return clamp(value, MIN_DIFFICULTY, MAX_DIFFICULTY)
}

//
// Questions
//

// Which way round a question is asked.
Choice_Type :: enum u8 {
	None,
	Auctions, // several auctions, one description -- pick the auction it describes
	Descriptions, // one auction, several descriptions -- pick the one that fits
}

// One question as the browser will see it.
Question :: struct {
	candidates:       []string,
	answer:           string,
	answer_candidate: string,
	choice_type:      Choice_Type,
}

// Where the right answer sits among the candidates.
answer_index :: proc(question: Question) -> (index: int, ok: bool) {
	for candidate, position in question.candidates {
		if candidate == question.answer_candidate {
			return position, true
		}
	}
	return 0, false
}

// How the parts of one auction are joined for display -- the same ` --> ` the panel app used, which
// the renderer then turns into a glyph.
AUCTION_SEPARATOR :: " --> "

// Bounds the "keep drawing until the descriptions are distinct" loop.
//
// The python spins forever if a working set holds fewer distinct non-blank descriptions than the
// question needs candidates, and it cannot happen in practice: a filter selecting fewer than
// MAX_DIFFICULTY auctions is rejected as `too_few` and the whole system is used instead. A task that
// never returns is a worse failure than a repeated candidate, so the loop gives up rather than
// hanging -- on any corpus where the python terminates, this bound is never reached.
@(private)
MAX_DRAWS :: 10_000

// `quiz.prettify_description`: trim, and spell the suit shorthand out. The remaining `!x`-to-glyph
// work is presentation and happens in the renderer.
prettify_description :: proc(text: string, allocator := context.allocator) -> string {
	trimmed := strings.trim_space(text)
	if !strings.contains(trimmed, "!") {
		return trimmed
	}
	out := strings.builder_make(0, len(trimmed), allocator)
	index := 0
	for index < len(trimmed) {
		if trimmed[index] != '!' || index + 1 >= len(trimmed) {
			strings.write_byte(&out, trimmed[index])
			index += 1
			continue
		}
		switch trimmed[index + 1] {
		case 'c':
			strings.write_byte(&out, 'C')
			index += 2
		case 'd':
			strings.write_byte(&out, 'D')
			index += 2
		case 'h':
			strings.write_byte(&out, 'H')
			index += 2
		case 's':
			strings.write_byte(&out, 'S')
			index += 2
		case:
			strings.write_byte(&out, '!')
			index += 1
		}
	}
	return strings.to_string(out)
}

//
// Scoring
//

// One answer's score, broken into the instalments the toasts reveal.
Points :: struct {
	from_candidate_lengths: int,
	from_streak_bonus:      int,
	from_time_bonus:        int,
}

points_total :: proc "contextless" (points: Points) -> int {
	return points.from_candidate_lengths + points.from_streak_bonus + points.from_time_bonus
}

// The verbatim port of `quiz_app.points` -- longer auctions are worth more, with a streak multiplier
// and a time multiplier on top.
score_points :: proc(question: Question, streak, percent_left: int) -> Points {
	base := 0
	for candidate in question.candidates {
		base += word_count_ignoring_arrows(candidate)
	}

	streak_bonus := 0
	if streak > 1 {
		percent_bonus := min(f64(streak) * 10.0 / 100.0, 1.0)
		streak_bonus = py_round(f64(base) * percent_bonus)
	}

	time_bonus := 0
	if percent_left > 0 {
		time_bonus = py_round(f64(base) * (f64(percent_left) / 100.0))
	}

	return Points{from_candidate_lengths = base, from_streak_bonus = streak_bonus, from_time_bonus = time_bonus}
}

// python's `candidate.replace("-->", "").split()` -- the arrows are separators, not words.
@(private = "file")
word_count_ignoring_arrows :: proc(candidate: string) -> (count: int) {
	rest := candidate
	in_word := false
	for index := 0; index < len(rest); index += 1 {
		if index + 3 <= len(rest) && rest[index:index + 3] == "-->" {
			index += 2
			continue
		}
		if is_space(rest[index]) {
			in_word = false
			continue
		}
		if !in_word {
			count += 1
			in_word = true
		}
	}
	return count
}

@(private = "file")
is_space :: #force_inline proc "contextless" (ch: u8) -> bool {
	return ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' || ch == '\v' || ch == '\f'
}

// One notification, and how long the stream should pause after showing it.
//
// `kind` matches the panel notification methods (success / info / warning) so the CSS can keep the
// same colour language.
Toast :: struct {
	kind:             string,
	text:             string,
	pause:            f64,
	// The running points total AS AT THIS TOAST. The state change is applied in one go, but the
	// panel app revealed the points in instalments, so each toast carries the number to show.
	points_after:     int,
	has_points_after: bool,
	// This beat is a milestone paying for a skip. A flag rather than a text match in the renderer:
	// the words are presentation and have been reworded once already, and "+1 SKIP!" appearing in
	// the stream handler would make an unrelated copy edit silently drop the gauge sweep and the
	// sound that go with it.
	awards_skip:      bool,
}

// The outcome of scoring one answer.
Answered :: struct {
	correct:       bool,
	toasts:        []Toast,
	completed:     bool,
	awarded_skips: int,
}

// The part of a session the score panel renders.
Score :: struct {
	questions_correct:    int,
	questions_attempted:  int,
	streak:               int,
	total_points:         int,
	// The milestones not yet collected, highest first -- popped from the BACK as the points pass
	// them, exactly as the python's reversed list is.
	available_milestones: [dynamic]f64,
}

make_score :: proc(allocator := context.allocator) -> Score {
	score := Score {
		available_milestones = make([dynamic]f64, 0, len(SCORE_MILESTONES), allocator),
	}
	reset_score(&score)
	return score
}

// Return the ledger to the start of a quiz.
reset_score :: proc(score: ^Score) {
	score.questions_correct = 0
	score.questions_attempted = 0
	score.streak = 0
	score.total_points = 0
	clear(&score.available_milestones)
	milestones := SCORE_MILESTONES
	#reverse for milestone in milestones {
		append(&score.available_milestones, milestone)
	}
}

// The proportion of attempts that were right.
score_percentage :: proc(score: Score) -> int {
	if score.questions_attempted == 0 {
		return 0
	}
	return py_round(f64(score.questions_correct) / f64(score.questions_attempted) * 100.0)
}

// Everything scoring one answer needs beyond the ledger.
Answer_Input :: struct {
	question:            Question,
	candidate:           string,
	percent_left:        int,
	ladder_mode:         bool,
	target_on:           bool,
	target_pct:          int,
	last_correct_points: int,
	// A parameter rather than the module constant, so the debug panel can shorten a quiz without a
	// global mutation -- the goal decides both completion and where the skip milestones fall, and
	// two sessions in one process may disagree.
	points_goal:         int,
}

// Score one answer. Mutates `score` and returns the toast script plus the new "last correct points"
// -- what a wrong answer costs in ladder mode.
//
// A wrong answer's toasts are deliberately brief: the answer itself is revealed in place in the
// question card, not spelled out in a notification the player has to wait behind.
answer :: proc(
	score: ^Score,
	input: Answer_Input,
	allocator := context.allocator,
) -> (
	result: Answered,
	last_correct_points: int,
) {
	correct := input.candidate == input.question.answer_candidate
	toasts := make([dynamic]Toast, 0, 8, allocator)

	if !correct {
		score.streak = 0
		score.questions_attempted += 1
		score_was_non_zero := score.total_points > 0
		if input.ladder_mode {
			score.total_points = max(score.total_points - input.last_correct_points, 0)
		}
		append(&toasts, Toast{kind = "warning", text = "Not quite", pause = 0.6})
		if input.ladder_mode && input.last_correct_points > 0 && score_was_non_zero {
			append(
				&toasts,
				Toast {
					kind = "warning",
					text = fmt.aprintf("Ladder mode: -%d points", input.last_correct_points, allocator = allocator),
					pause = 0.6,
					points_after = score.total_points,
					has_points_after = true,
				},
			)
		}
		return Answered{correct = false, toasts = toasts[:]}, input.last_correct_points
	}

	score.streak += 1
	increase := score_points(input.question, score.streak, input.percent_left)

	append(&toasts, Toast{kind = "success", text = "Correct!", pause = 0.5})

	score.total_points += increase.from_candidate_lengths
	append(
		&toasts,
		Toast {
			kind = "info",
			text = fmt.aprintf("+%d!", increase.from_candidate_lengths, allocator = allocator),
			pause = 0.5,
			points_after = score.total_points,
			has_points_after = true,
		},
	)

	if increase.from_streak_bonus > 0 {
		score.total_points += increase.from_streak_bonus
		append(
			&toasts,
			Toast {
				kind = "info",
				text = fmt.aprintf(
					"Streak %d, Bonus +%d",
					score.streak,
					increase.from_streak_bonus,
					allocator = allocator,
				),
				pause = 0.5,
				points_after = score.total_points,
				has_points_after = true,
			},
		)
	}

	if increase.from_time_bonus > 0 {
		score.total_points += increase.from_time_bonus
		append(
			&toasts,
			Toast {
				kind = "info",
				text = fmt.aprintf("Time Bonus +%d", increase.from_time_bonus, allocator = allocator),
				pause = 0.5,
				points_after = score.total_points,
				has_points_after = true,
			},
		)
	}

	score.questions_attempted += 1
	score.questions_correct += 1

	awarded_skips := 0
	for len(score.available_milestones) > 0 {
		last := score.available_milestones[len(score.available_milestones) - 1]
		if last * f64(input.points_goal) > f64(score.total_points) {
			break
		}
		pop(&score.available_milestones)
		awarded_skips += 1
		append(&toasts, Toast{kind = "success", text = "+1 SKIP!", pause = 0.5, awards_skip = true})
	}

	completed := false
	if score.total_points >= input.points_goal {
		percentage := score_percentage(score^)
		if !input.target_on || percentage >= input.target_pct {
			completed = true
		} else {
			append(
				&toasts,
				Toast {
					kind = "warning",
					text = fmt.aprintf(
						"Current score %d%%, target score %d%%",
						percentage,
						input.target_pct,
						allocator = allocator,
					),
					pause = 0.5,
				},
			)
		}
	}

	// The panel handler paused a further second before moving on when the answer was right.
	append(&toasts, Toast{kind = "info", text = "", pause = 1.0})

	return Answered {
		correct = true,
		toasts = toasts[:],
		completed = completed,
		awarded_skips = awarded_skips,
	}, points_total(increase)
}

_ :: corpus
