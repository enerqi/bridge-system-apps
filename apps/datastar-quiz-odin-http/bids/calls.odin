// The calls a token can stand for, and the comparisons the corpus loader needs.
//
// Everything that produces a set of calls writes into a caller-supplied slice and returns the prefix
// it filled, rather than returning an allocation. `calls_at_or_above` is the widest of them: `1C+`
// is every bid there is, which is 35.
package bids

import "core:strings"

// Every bid there is: seven levels of five denominations. The ceiling for `calls_at_or_above`.
CALLS_MAX :: 35

// The cheapest bid above `bid` -- one denomination up, or the next level starting at clubs when
// `bid` was notrump.
//
// Only defined for a bid naming ONE denomination: after a token that could be several calls (`4HS`,
// `3x`, `any`) there is no single next step. Fails at the ceiling (7N) and for non-bids.
next_call :: proc "contextless" (bid: Bid) -> (next: Bid, ok: bool) {
	if !is_bid(bid) || bid.level == 0 || suits_count(bid.suits) != 1 {
		return {}, false
	}
	rank := suit_rank(bid.suits)
	next = bid
	next.suit_class = .None
	if rank == 5 {
		if bid.level == 7 {
			return {}, false
		}
		next.level = bid.level + 1
		next.suits = CLUBS
		return next, true
	}
	next.suits = suit_from_rank(rank + 1)
	return next, true
}

// The `steps`-th call above `previous`, counting the cheapest as step 1. This is the ladder
// artificial asks answer on: over a 4N keycard ask, 5C is step 1.
step_call :: proc "contextless" (previous: Bid, steps: u8) -> (call: Bid, ok: bool) {
	call = previous
	for _ in 0 ..< steps {
		call, ok = next_call(call)
		if !ok {
			return {}, false
		}
	}
	return call, true
}

// The lowest bid in `suit` that is legal over `previous`: the same level when `suit` outranks the
// previous denomination, one level up otherwise. Fails past 7, or when `previous` is not one
// specific bid (`4HS` could be either, and each answer differs).
cheapest_call :: proc "contextless" (previous: Bid, suit: Suits) -> (call: Bid, ok: bool) {
	if !is_bid(previous) || previous.level == 0 || suits_count(previous.suits) != 1 {
		return {}, false
	}
	was := suit_rank(previous.suits)
	level := suit_rank(suit) > was ? previous.level : previous.level + 1
	if level > 7 {
		return {}, false
	}
	call = previous
	call.level = level
	call.suits = suit
	call.suit_class = .None
	call.jump_levels = 0
	return call, true
}

// The game contracts: 3N, 4H, 4S, 5C, 5D.
game_calls :: proc(by_opponent: bool, out: []Bid) -> []Bid {
	table := GAME_CALLS
	count := min(len(out), len(table))
	for index in 0 ..< count {
		call := plain(.Bid, by_opponent)
		call.level = table[index].level
		call.suits = table[index].suits
		out[index] = call
	}
	return out[:count]
}

// Every bid from `bid` upwards, for an `at_least` token like `2N+`. Enumerating them keeps matching
// a plain set intersection instead of needing a comparison operator in the pattern language.
calls_at_or_above :: proc(bid: Bid, out: []Bid) -> []Bid {
	if bid.level == 0 || bid.suits == NO_SUITS {
		return out[:0]
	}
	floor := u8(6)
	for suit in ALPHABETICAL {
		if suit & bid.suits != NO_SUITS {
			floor = min(floor, suit_rank(suit))
		}
	}

	count := 0
	for level := bid.level; level <= 7; level += 1 {
		for rank in u8(1) ..= 5 {
			if level == bid.level && rank < floor {
				continue
			}
			if count >= len(out) {
				return out[:count]
			}
			call := plain(.Bid, bid.by_opponent)
			call.level = level
			call.suits = suit_from_rank(rank)
			out[count] = call
			count += 1
		}
	}
	return out[:count]
}

// python's `min(calls, key=lambda c: (c.level, SUIT_RANK[...]))`.
lowest_call :: proc "contextless" (calls: []Bid) -> (lowest: Bid, ok: bool) {
	if len(calls) == 0 {
		return {}, false
	}
	lowest = calls[0]
	for call in calls[1:] {
		if call.level < lowest.level ||
		   (call.level == lowest.level && suit_rank(call.suits) < suit_rank(lowest.suits)) {
			lowest = call
		}
	}
	return lowest, true
}

//
// Comparisons, for the corpus loader
//

// True for a real bid (not a pass, a double or prose). Multi-suit counts, and so does an alternation
// of bids -- including `3S/4C`, which spans levels and so has no single-Bid form to ask about.
is_bid_token :: proc(token: string) -> bool {
	buffer: [ALTERNATIVES_MAX]Bid
	calls := parse_call_alternatives(token, buffer[:])
	if len(calls) == 0 {
		return false
	}
	for call in calls {
		if !is_bid(call) {
			return false
		}
	}
	return true
}

@(private = "file")
one_less_than :: proc "contextless" (left, right: Bid) -> bool {
	if !is_bid(left) || left.level == 0 || !is_bid(right) || right.level == 0 {
		return false
	}
	if left.level != right.level {
		return left.level < right.level
	}
	// Same level: every denomination the left could be must rank below every one the right could
	// be, so compare the left's highest against the right's lowest.
	highest := u8(0)
	lowest := u8(6)
	for suit in ALPHABETICAL {
		if suit & left.suits != NO_SUITS {
			highest = max(highest, suit_rank(suit))
		}
		if suit & right.suits != NO_SUITS {
			lowest = min(lowest, suit_rank(suit))
		}
	}
	return highest < lowest
}

// Does `left` rank strictly below `right` in the auction?
//
// Strict throughout, because the caller is asking "did this call have to come first?" and a wrong
// yes invents an auction. A multi-suit bid is below another call only when EVERY denomination it
// allows is, and an alternation only when every branch is. Non-bids compare as false.
bid_less_than :: proc(left, right: string) -> bool {
	left_buffer, right_buffer: [ALTERNATIVES_MAX]Bid
	lefts := parse_call_alternatives(left, left_buffer[:])
	rights := parse_call_alternatives(right, right_buffer[:])
	if len(lefts) == 0 || len(rights) == 0 {
		return false
	}
	for l in lefts {
		for r in rights {
			if !one_less_than(l, r) {
				return false
			}
		}
	}
	return true
}

// Render a call the way bml writes it. For diagnostics and test failure messages.
write_call :: proc(builder: ^strings.Builder, bid: Bid) {
	if bid.by_opponent {
		strings.write_byte(builder, '(')
	}
	switch bid.kind {
	case .Bid:
		if bid.level > 0 {
			strings.write_byte(builder, '0' + bid.level)
		}
		for suit in ALPHABETICAL {
			if suit & bid.suits != NO_SUITS {
				strings.write_byte(builder, suit_to_char(suit))
			}
		}
	case .Pass:
		strings.write_string(builder, "Pass")
	case .Double:
		strings.write_byte(builder, 'X')
	case .Redouble:
		strings.write_string(builder, "XX")
	case .Other,
	     .Any,
	     .Any_Bid,
	     .Any_Call,
	     .Game,
	     .At_Least,
	     .Next,
	     .Jump,
	     .Cue,
	     .Cue_Over,
	     .Cue_Low,
	     .Cue_High,
	     .New,
	     .Step,
	     .Raise,
	     .Strain,
	     .Strain_Any,
	     .Slam,
	     .Next_Suit,
	     .Fourth_Suit:
		write_kind_name(builder, bid.kind)
	}
	if bid.by_opponent {
		strings.write_byte(builder, ')')
	}
}

@(private = "file")
write_kind_name :: proc(builder: ^strings.Builder, kind: Kind) {
	names := [Kind]string {
		.Other       = "other",
		.Bid         = "bid",
		.Pass        = "pass",
		.Double      = "double",
		.Redouble    = "redouble",
		.Any         = "any",
		.Any_Bid     = "any_bid",
		.Any_Call    = "any_call",
		.Game        = "game",
		.At_Least    = "at_least",
		.Next        = "next",
		.Jump        = "jump",
		.Cue         = "cue",
		.Cue_Over    = "cue_over",
		.Cue_Low     = "cue_low",
		.Cue_High    = "cue_high",
		.New         = "new",
		.Step        = "step",
		.Raise       = "raise",
		.Strain      = "strain",
		.Strain_Any  = "strain_any",
		.Slam        = "slam",
		.Next_Suit   = "next_suit",
		.Fourth_Suit = "fourth_suit",
	}
	strings.write_string(builder, names[kind])
}
