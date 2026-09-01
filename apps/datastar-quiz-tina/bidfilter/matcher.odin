// Matching an auction against a pattern, and turning a raw auction into the concrete auctions it
// stands for.
package bidfilter

import "../bids"
import "../flat"
import "core:strings"

// A parsed auction: one group per POSITION, holding the calls that position allows. One for an
// ordinary call, several for `2D/2H`.
Auction :: flat.Flat(bids.Bid)

// The concrete auctions one written auction stands for -- one, unless correlated suit classes bind
// or a relative token like `next` resolves several ways.
Variants :: [dynamic]Auction

// Does one call satisfy one alternative of a pattern position?
//
// Both sides can name a SET of calls -- the auction may record `1HS` or `2D/2H`, the pattern may ask
// for `1M` or `3S/4C` -- so this is a test for overlap, not equality.
bid_matches :: proc "contextless" (bid: bids.Bid, pattern: Bid_Pattern) -> bool {
	#partial switch bid.kind {
	case .Any, .Any_Bid, .Any_Call:
		// A catch-all row -- "whatever is called here" -- so it answers to any pattern, subject to
		// whose call it was and to how much the word promised: `(overcall)` is a bid, `(bid)` is
		// anything but a pass, `any`/`other(s)` is anything at all.
		if !side_accepts(pattern.side, bid.by_opponent) {
			return false
		}
		#partial switch bid.kind {
		case .Any_Bid:
			return pattern.kind == .Bid || pattern.kind == .Wildcard
		case .Any_Call:
			return pattern.kind != .Pass
		}
		return true
	}

	kinds_agree: bool
	switch pattern.kind {
	case .Wildcard:
		kinds_agree = true
	case .Bid:
		kinds_agree = bid.kind == .Bid
	case .Pass:
		kinds_agree = bid.kind == .Pass
	case .Double:
		kinds_agree = bid.kind == .Double
	case .Redouble:
		kinds_agree = bid.kind == .Redouble
	}
	if !kinds_agree || !side_accepts(pattern.side, bid.by_opponent) {
		return false
	}
	if pattern.kind == .Bid {
		if pattern.level != 0 && pattern.level != bid.level {
			return false
		}
		if pattern.suits != bids.NO_SUITS && bid.suits & pattern.suits == bids.NO_SUITS {
			return false
		}
	}
	return true
}

// As `bid_matches`, when the AUCTION position is itself a set of calls.
//
// `1HS--3S/4C` records a position no single Bid can express, so an auction position is a set of
// alternatives. It matches when any of them does: the recorded auction is one of these calls, and
// the filter is asking whether it could be the one wanted.
position_matches :: proc "contextless" (position: []bids.Bid, alternatives: []Bid_Pattern) -> bool {
	for bid in position {
		for alternative in alternatives {
			if bid_matches(bid, alternative) {
				return true
			}
		}
	}
	return false
}

// Must this position line up with the very next call rather than skipping over opponent calls? True
// for anything bracketed and for the bare `*`.
@(private = "file")
anchored :: proc "contextless" (alternatives: []Bid_Pattern) -> bool {
	for alternative in alternatives {
		if alternative.side == .Theirs || alternative.kind == .Wildcard {
			return true
		}
	}
	return false
}

// Does the auction begin with the pattern?
//
// A pattern describes OUR auction. The opponents can slip a call in at any point, so opponent calls
// the pattern does not ask about are stepped over rather than failing the match: `1D-1H` matches
// 1D (Pass) 1H, 1D (1S) 1H and 1D (X) 1H alike.
//
// Three kinds of token opt out of that skipping and line up with whatever call comes next:
//   - the FIRST token, because this is a prefix match: it anchors to the opening call, so `2C` means
//     we opened 2C, not that we bid 2C at some point after an opponent's opening;
//   - a bracketed token -- `(X)`, `(2H)`, `(*)` -- which is ABOUT the opponents;
//   - the bare wildcard `*`, meaning "any call at all" including an opponent's, which is what makes
//     `*-*-*-*-*-*` mean "six calls deep" rather than "six calls by us".
matches_prefix :: proc(auction: Auction, pattern: Pattern) -> bool {
	index := 0
	for position in 0 ..< flat.group_count(pattern) {
		alternatives := flat.group(pattern, position)
		if position > 0 && !anchored(alternatives) {
			for index < flat.group_count(auction) && all_by_opponent(flat.group(auction, index)) {
				index += 1
			}
		}
		if index >= flat.group_count(auction) {
			return false
		}
		if !position_matches(flat.group(auction, index), alternatives) {
			return false
		}
		index += 1
	}
	return true
}

@(private = "file")
all_by_opponent :: proc "contextless" (position: []bids.Bid) -> bool {
	for bid in position {
		if !bid.by_opponent {
			return false
		}
	}
	return true
}

// Does a pre-parsed auction match ANY of the patterns (comma = OR)?
bids_match_any :: proc(variants: []Auction, patterns: []Pattern) -> bool {
	for auction in variants {
		for pattern in patterns {
			if matches_prefix(auction, pattern) {
				return true
			}
		}
	}
	return false
}

// Parse an auction into one entry per position, each the calls that position allows.
//
// Unlike a flat call parse this keeps `3S/4C` -- an alternation spanning levels, which has no
// single-Bid form -- instead of degrading it to `.Other`.
parse_sequence_positions :: proc(sequence: []string, allocator := context.allocator) -> Auction {
	auction := flat.make_flat(bids.Bid, len(sequence), len(sequence), allocator)
	for element in sequence {
		rest := element
		for {
			token, remaining, found := next_field(rest)
			if token != "" {
				before := flat.open_len(auction)
				alternatives: [bids.ALTERNATIVES_MAX]bids.Bid
				for call in bids.parse_call_alternatives(token, alternatives[:]) {
					#partial switch call.kind {
					case .At_Least:
						// `2N+` names its own floor, so it needs no auction: expand it here into
						// the calls it allows.
						expanded: [bids.CALLS_MAX]bids.Bid
						for bid in bids.calls_at_or_above(call, expanded[:]) {
							flat.push_item(&auction, bid)
						}
					case .Game:
						// a game contract: 3N, 4H, 4S, 5C or 5D
						games: [8]bids.Bid
						for bid in bids.game_calls(call.by_opponent, games[:]) {
							flat.push_item(&auction, bid)
						}
					case:
						flat.push_item(&auction, call)
					}
				}
				if flat.open_len(auction) > before {
					flat.close_group(&auction)
				}
			}
			if !found {
				break
			}
			rest = remaining
		}
	}
	return auction
}

// Drop opponent passes. They are noise for filtering -- the auction notation omits them anyway --
// and dropping them is what lets `(*)` mean "the opponents actually did something". Active opponent
// calls like `(X)` or `(1S)` are kept, and `matches_prefix` decides whether to step over them.
significant_positions :: proc(auction: Auction, allocator := context.allocator) -> Auction {
	out := flat.make_flat(bids.Bid, flat.group_count(auction), flat.item_count(auction), allocator)
	for index in 0 ..< flat.group_count(auction) {
		position := flat.group(auction, index)
		if !all_opponent_passes(position) {
			flat.push_group(&out, position)
		}
	}
	return out
}

@(private = "file")
all_opponent_passes :: proc "contextless" (position: []bids.Bid) -> bool {
	for bid in position {
		if !bid.by_opponent || bid.kind != .Pass {
			return false
		}
	}
	return true
}

// Turn one auction into the concrete auctions it stands for: parsed into positions, opponent passes
// dropped, suit classes bound, `next` and its relatives resolved.
prepare_auction :: proc(sequence: []string, allocator := context.allocator) -> Variants {
	parsed := parse_sequence_positions(sequence, context.temp_allocator)
	positions := significant_positions(parsed, context.temp_allocator)

	out := make(Variants, 0, 1, allocator)
	correlated := expand_correlated(positions, context.temp_allocator)
	for variant in correlated {
		resolved := resolve_relative(variant, allocator)
		for auction in resolved {
			append(&out, auction)
		}
		delete(resolved)
	}
	return out
}

destroy_variants :: proc(variants: ^Variants) {
	for &auction in variants {
		flat.destroy(&auction)
	}
	delete(variants^)
}

// Parse a raw auction and prefix-match it against any of the patterns. Convenience for tests and
// one-off checks; the app pre-parses instead.
sequence_matches_any :: proc(sequence: []string, patterns: []Pattern) -> bool {
	variants := prepare_auction(sequence, context.temp_allocator)
	defer delete(variants)
	return bids_match_any(variants[:], patterns)
}

// Split on runs of whitespace, the way python's `str.split()` does.
@(private = "file")
next_field :: proc(text: string) -> (field, rest: string, more: bool) {
	start := 0
	for start < len(text) && is_ascii_space(text[start]) {
		start += 1
	}
	if start >= len(text) {
		return "", "", false
	}
	end := start
	for end < len(text) && !is_ascii_space(text[end]) {
		end += 1
	}
	return text[start:end], text[end:], end < len(text)
}

@(private = "file")
is_ascii_space :: #force_inline proc "contextless" (ch: u8) -> bool {
	return ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' || ch == '\v' || ch == '\f'
}

_ :: strings
