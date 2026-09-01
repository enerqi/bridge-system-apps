// The call model, case by case.
//
// These follow `apps/quiz/tests/test_bidfilter.py` and the Go port's `internal/bids` cases, keeping
// the ones that are about the call SYNTAX; the pattern-language cases live with the matcher.
package bids

import "core:strings"
import "core:testing"

@(private = "file")
parsed :: proc(t: ^testing.T, token: string) -> Bid {
	bid, ok := parse_call(token)
	testing.expectf(t, ok, "%q did not parse at all", token)
	return bid
}

@(private = "file")
expect_bid :: proc(t: ^testing.T, token: string, level: u8, suits: Suits, loc := #caller_location) {
	bid, ok := parse_call(token)
	testing.expectf(t, ok, "%q did not parse at all", token, loc = loc)
	testing.expectf(t, bid.kind == .Bid, "%q parsed as %v, wanted a bid", token, bid.kind, loc = loc)
	testing.expectf(
		t,
		bid.level == level && bid.suits == suits,
		"%q parsed as %d%v, wanted %d%v",
		token,
		bid.level,
		bid.suits,
		level,
		suits,
		loc = loc,
	)
}

@(test)
test_a_plain_bid_is_a_level_and_a_denomination :: proc(t: ^testing.T) {
	expect_bid(t, "1C", 1, CLUBS)
	expect_bid(t, "3H", 3, HEARTS)
	expect_bid(t, "7N", 7, NOTRUMP)
}

@(test)
test_notrump_is_written_either_way :: proc(t: ^testing.T) {
	expect_bid(t, "1N", 1, NOTRUMP)
	expect_bid(t, "1NT", 1, NOTRUMP)
	expect_bid(t, "3nt", 3, NOTRUMP)
}

@(test)
test_a_multi_suit_bid_holds_every_denomination_it_allows :: proc(t: ^testing.T) {
	expect_bid(t, "1HS", 1, HEARTS | SPADES)
	expect_bid(t, "2CD", 2, MINORS)
}

// The one place case is significant in the whole language: `M` is the majors, `m` the minors.
@(test)
test_case_is_significant_only_for_the_suit_classes :: proc(t: ^testing.T) {
	major := parsed(t, "2M")
	testing.expect_value(t, major.suits, MAJORS)
	testing.expect_value(t, major.suit_class, Suit_Class.Major)

	minor := parsed(t, "3m")
	testing.expect_value(t, minor.suits, MINORS)
	testing.expect_value(t, minor.suit_class, Suit_Class.Minor)

	// everything else folds
	expect_bid(t, "1c", 1, CLUBS)
	expect_bid(t, "1C", 1, CLUBS)
}

@(test)
test_the_other_major_is_a_class_not_a_denomination :: proc(t: ^testing.T) {
	other := parsed(t, "oM")
	testing.expect_value(t, other.suit_class, Suit_Class.Other_Major)
	testing.expect_value(t, other.suits, MAJORS)
	testing.expect_value(t, other.level, u8(0)) // no level: "the other major, whenever it comes"
	testing.expect(t, is_other_class(other.suit_class))

	levelled := parsed(t, "3oM")
	testing.expect_value(t, levelled.level, u8(3))
	testing.expect_value(t, levelled.suit_class, Suit_Class.Other_Major)
}

@(test)
test_a_wildcard_level_allows_every_denomination :: proc(t: ^testing.T) {
	expect_bid(t, "3*", 3, ALL_SUITS)
	expect_bid(t, "3x", 3, ALL_SUITS)
}

@(test)
test_suit_shorthand_is_expanded :: proc(t: ^testing.T) {
	expect_bid(t, "1!h", 1, HEARTS)
	expect_bid(t, "2!c", 2, CLUBS)
}

// A denomination on its own, with no level, is a `strain` -- "the simple bid in that suit, at
// whatever level the auction has reached".
@(test)
test_a_bare_denomination_is_a_strain :: proc(t: ^testing.T) {
	diamonds := parsed(t, "!d")
	testing.expect_value(t, diamonds.kind, Kind.Strain)
	testing.expect_value(t, diamonds.suits, DIAMONDS)
}

// `!d` is diamonds, but a bare `D` is deliberately excluded from that rule -- `raw_inner.upper() !=
// "D"` in the python, guarding on the token as WRITTEN rather than after shorthand expansion.
//
// It does NOT become the double, though: `DOUBLE_TOKENS` is `{X, DBL}` and does not contain `D`, so
// a lone `D` falls through to prose. Worth pinning, because both other ports carry a comment saying
// it is the double and the code in all three agrees it is not.
@(test)
test_a_bare_d_is_neither_diamonds_nor_the_double :: proc(t: ^testing.T) {
	testing.expect_value(t, parsed(t, "D").kind, Kind.Other)

	testing.expect_value(t, parsed(t, "X").kind, Kind.Double)
	testing.expect_value(t, parsed(t, "DBL").kind, Kind.Double)
	testing.expect_value(t, parsed(t, "XX").kind, Kind.Redouble)
	testing.expect_value(t, parsed(t, "R").kind, Kind.Redouble)
	testing.expect_value(t, parsed(t, "Pass").kind, Kind.Pass)
	testing.expect_value(t, parsed(t, "P").kind, Kind.Pass)
}

@(test)
test_brackets_mean_the_opponents_called :: proc(t: ^testing.T) {
	theirs := parsed(t, "(1S)")
	testing.expect(t, theirs.by_opponent)
	testing.expect_value(t, theirs.level, u8(1))
	testing.expect_value(t, theirs.suits, SPADES)

	testing.expect(t, parsed(t, "(X)").by_opponent)
	testing.expect(t, !parsed(t, "1S").by_opponent)
}

@(test)
test_a_call_written_as_a_link_is_its_label :: proc(t: ^testing.T) {
	expect_bid(t, "[1D](#1C--1D)", 1, DIAMONDS)
	// prose in the label is not a call, so the link is left alone and parses as prose
	testing.expect_value(t, parsed(t, "[some text](#anchor)").kind, Kind.Other)
}

// `2D/2H` is ONE position with two possibilities, and when they differ only in denomination it
// collapses to the same thing as `2DH`.
@(test)
test_alternatives_at_one_position_merge_when_they_can :: proc(t: ^testing.T) {
	expect_bid(t, "2D/2H", 2, DIAMONDS | HEARTS)

	// spanning levels, it cannot be one Bid at all
	spanning := parsed(t, "3S/4C")
	testing.expect_value(t, spanning.kind, Kind.Other)

	// both branches are still bids, which is what the corpus loader asks about
	testing.expect(t, is_bid_token("3S/4C"))
}

@(test)
test_brackets_round_an_alternation_reach_every_branch :: proc(t: ^testing.T) {
	buffer: [ALTERNATIVES_MAX]Bid
	calls := parse_call_alternatives("(2D/2H)", buffer[:])
	testing.expect_value(t, len(calls), 2)
	for call in calls {
		testing.expect(t, call.by_opponent)
	}
}

@(test)
test_the_relative_tokens_are_recognised :: proc(t: ^testing.T) {
	Case :: struct {
		token: string,
		kind:  Kind,
	}
	cases := []Case {
		{"next", .Next},
		{"jump", .Jump},
		{"cue", .Cue},
		{"cuelow", .Cue_Low},
		{"cuehigh", .Cue_High},
		{"cuehi", .Cue_High},
		{"cueover", .Cue_Over},
		{"new", .New},
		{"newsuit", .New},
		{"4thsuit", .Fourth_Suit},
		{"nextsuit", .Next_Suit},
		{"raise", .Raise},
		{"jumpraise", .Raise},
		{"xstep", .Step},
		{"2step", .Step},
		{"step2", .Step},
		{"slam", .Slam},
		{"game", .Game},
		{"any", .Any},
		{"other", .Any},
		{"overcall", .Any_Bid},
		{"higher", .Any_Bid},
		{"bid", .Any_Call},
	}
	for test_case in cases {
		bid := parsed(t, test_case.token)
		testing.expectf(
			t,
			bid.kind == test_case.kind,
			"%q parsed as %v, wanted %v",
			test_case.token,
			bid.kind,
			test_case.kind,
		)
	}

	// every one of those has to be resolved against the auction before it can match
	testing.expect(t, is_relative(.Next))
	testing.expect(t, is_relative(.Fourth_Suit))
	testing.expect(t, !is_relative(.Bid))
	testing.expect(t, !is_relative(.Pass))
}

@(test)
test_jump_carries_how_far_it_jumps :: proc(t: ^testing.T) {
	testing.expect_value(t, parsed(t, "jump").jump_levels, u8(1))
	testing.expect_value(t, parsed(t, "doublejump").jump_levels, u8(2))
	testing.expect_value(t, parsed(t, "jumpraise").jump_levels, u8(1))
	testing.expect_value(t, parsed(t, "raise").jump_levels, u8(0))
}

@(test)
test_a_strain_with_no_level_is_the_simple_bid_in_it :: proc(t: ^testing.T) {
	strain := parsed(t, "!c")
	testing.expect_value(t, strain.kind, Kind.Strain)
	testing.expect_value(t, strain.suits, CLUBS)

	any_level := parsed(t, "!c+")
	testing.expect_value(t, any_level.kind, Kind.Strain_Any)
	testing.expect_value(t, any_level.suits, CLUBS)
}

@(test)
test_prose_parses_as_other_rather_than_failing :: proc(t: ^testing.T) {
	testing.expect_value(t, parsed(t, "nonsense!!").kind, Kind.Other)
	testing.expect_value(t, parsed(t, "a whole sentence here").kind, Kind.Other)

	_, ok := parse_call("   ")
	testing.expect(t, !ok, "blank input should not parse at all")
}

//
// Enumerating the calls a token stands for
//

@(test)
test_the_next_call_walks_denominations_then_levels :: proc(t: ^testing.T) {
	one_club := parsed(t, "1C")
	next, ok := next_call(one_club)
	testing.expect(t, ok)
	testing.expect_value(t, next.level, u8(1))
	testing.expect_value(t, next.suits, DIAMONDS)

	// notrump is the top of a level, so the next call is clubs one level up
	one_notrump := parsed(t, "1N")
	next, ok = next_call(one_notrump)
	testing.expect(t, ok)
	testing.expect_value(t, next.level, u8(2))
	testing.expect_value(t, next.suits, CLUBS)

	// nothing is above 7N
	_, ok = next_call(parsed(t, "7N"))
	testing.expect(t, !ok, "7N is the ceiling")

	// a multi-suit token has no single next step
	_, ok = next_call(parsed(t, "1HS"))
	testing.expect(t, !ok, "a multi-suit bid has no one successor")
}

// Over a 4N keycard ask, 5C is step 1 -- the ladder artificial asks answer on.
@(test)
test_steps_count_from_the_cheapest_call :: proc(t: ^testing.T) {
	ask := parsed(t, "4N")
	first, ok := step_call(ask, 1)
	testing.expect(t, ok)
	testing.expect_value(t, first.level, u8(5))
	testing.expect_value(t, first.suits, CLUBS)

	third, third_ok := step_call(ask, 3)
	testing.expect(t, third_ok)
	testing.expect_value(t, third.level, u8(5))
	testing.expect_value(t, third.suits, HEARTS)
}

@(test)
test_the_cheapest_call_in_a_suit_stays_at_the_level_when_it_outranks :: proc(t: ^testing.T) {
	// spades outrank hearts, so it fits at the same level
	over_hearts := parsed(t, "1H")
	call, ok := cheapest_call(over_hearts, SPADES)
	testing.expect(t, ok)
	testing.expect_value(t, call.level, u8(1))
	testing.expect_value(t, call.suits, SPADES)

	// clubs do not, so it costs a level
	call, ok = cheapest_call(over_hearts, CLUBS)
	testing.expect(t, ok)
	testing.expect_value(t, call.level, u8(2))
	testing.expect_value(t, call.suits, CLUBS)
}

@(test)
test_at_least_enumerates_every_call_above_it :: proc(t: ^testing.T) {
	buffer: [CALLS_MAX]Bid
	// 7N+ is just 7N
	calls := calls_at_or_above(Bid{level = 7, suits = NOTRUMP, kind = .Bid}, buffer[:])
	testing.expect_value(t, len(calls), 1)
	testing.expect_value(t, calls[0].suits, NOTRUMP)

	// 1C+ is every bid there is
	calls = calls_at_or_above(Bid{level = 1, suits = CLUBS, kind = .Bid}, buffer[:])
	testing.expect_value(t, len(calls), CALLS_MAX)

	// 7S+ is 7S and 7N -- the floor applies only on the token's own level
	calls = calls_at_or_above(Bid{level = 7, suits = SPADES, kind = .Bid}, buffer[:])
	testing.expect_value(t, len(calls), 2)
}

@(test)
test_the_game_calls_are_the_five_game_contracts :: proc(t: ^testing.T) {
	buffer: [8]Bid
	calls := game_calls(false, buffer[:])
	testing.expect_value(t, len(calls), 5)
	testing.expect_value(t, calls[0].level, u8(3))
	testing.expect_value(t, calls[0].suits, NOTRUMP)
	testing.expect_value(t, calls[4].level, u8(5))
	testing.expect_value(t, calls[4].suits, DIAMONDS)
}

@(test)
test_the_lowest_call_orders_by_level_then_denomination :: proc(t: ^testing.T) {
	calls := []Bid {
		{level = 2, suits = HEARTS, kind = .Bid},
		{level = 1, suits = SPADES, kind = .Bid},
		{level = 1, suits = CLUBS, kind = .Bid},
	}
	lowest, ok := lowest_call(calls)
	testing.expect(t, ok)
	testing.expect_value(t, lowest.level, u8(1))
	testing.expect_value(t, lowest.suits, CLUBS)
}

// Strict throughout: the caller is asking "did this call have to come first?", and a wrong yes
// invents an auction.
@(test)
test_ranking_one_call_below_another_is_strict :: proc(t: ^testing.T) {
	testing.expect(t, bid_less_than("1C", "1D"))
	testing.expect(t, bid_less_than("1N", "2C"))
	testing.expect(t, !bid_less_than("1D", "1C"))
	testing.expect(t, !bid_less_than("1C", "1C"))

	// a multi-suit bid is below another call only when every denomination it allows is
	testing.expect(t, bid_less_than("1CD", "1S"))
	testing.expect(t, !bid_less_than("1CD", "1D"))

	// non-bids never compare
	testing.expect(t, !bid_less_than("Pass", "1C"))
	testing.expect(t, !bid_less_than("1C", "X"))
}

@(test)
test_only_real_bids_are_bid_tokens :: proc(t: ^testing.T) {
	testing.expect(t, is_bid_token("1C"))
	testing.expect(t, is_bid_token("1HS"))
	testing.expect(t, is_bid_token("2D/2H"))
	testing.expect(t, !is_bid_token("Pass"))
	testing.expect(t, !is_bid_token("X"))
	testing.expect(t, !is_bid_token("prose here"))
	testing.expect(t, !is_bid_token(""))
}

@(test)
test_a_call_renders_the_way_bml_writes_it :: proc(t: ^testing.T) {
	Case :: struct {
		token, rendered: string,
	}
	cases := []Case{{"1C", "1C"}, {"1HS", "1HS"}, {"(1S)", "(1S)"}, {"Pass", "Pass"}, {"X", "X"}, {"XX", "XX"}}
	for test_case in cases {
		builder := strings.builder_make(context.temp_allocator)
		write_call(&builder, parsed(t, test_case.token))
		testing.expect_value(t, strings.to_string(builder), test_case.rendered)
	}
}

// Alphabetical, because that is the order python's `sorted(frozenset)` produces, and the generated
// variants have to come out in the same order as the reference implementation's. N between H and S
// is the part that looks wrong and is not.
@(test)
test_denominations_enumerate_alphabetically :: proc(t: ^testing.T) {
	builder := strings.builder_make(context.temp_allocator)
	for suit in ALPHABETICAL {
		strings.write_byte(&builder, suit_to_char(suit))
	}
	testing.expect_value(t, strings.to_string(builder), "CDHNS")
}
