// Correlated suit classes and relative calls -- the two things that make one written auction stand
// for more than one concrete auction.
package bidfilter

import "../bids"
import "../flat"
import "base:runtime"

//
// Correlated suit classes
//
// `1HS--2M` is "1H then 2H, or 1S then 2S" -- one major, named twice. Matching each position
// independently also accepts 1H then 2S, an auction the section never described. The corpus proves
// the intent: it writes `oM` when it means THE OTHER major, which would be pointless if a repeated
// `M` did not mean the same one.
//
// Rather than binding variables inside the matcher -- which would make it stateful and need
// backtracking -- an auction is expanded into the concrete auctions it stands for, and matches if
// any of them does. For a single set-valued position that is identical to the plain overlap test;
// it only tightens where two positions share a class.
//

// A suit class is a proper subset of the denominations: {H,S} and {C,D} bind, the five-denomination
// wildcard (`3*`) does not -- two wildcards in an auction are unrelated, not "the same unknown
// suit".
BINDABLE :: [2]bids.Suits{bids.MAJORS, bids.MINORS}

// The class this call's denomination is drawn from, if it is one that binds, or none.
//
// A concrete call counts: `1H` is a use of the majors class, which is what lets a later `2oM` mean
// spades.
@(private = "file")
binding_class :: proc "contextless" (bid: bids.Bid) -> bids.Suits {
	if !bids.is_bid(bid) || bid.suits == bids.NO_SUITS {
		return bids.NO_SUITS
	}
	if bid.suit_class != .None {
		class := bids.class_suits(bid)
		for bindable in BINDABLE {
			if class == bindable {
				return class
			}
		}
		return bids.NO_SUITS
	}
	for bindable in BINDABLE {
		if bid.suits & ~bindable == bids.NO_SUITS {
			return bindable
		}
	}
	return bids.NO_SUITS
}

@(private = "file")
bindable_slot :: proc "contextless" (class: bids.Suits) -> (slot: int, ok: bool) {
	for bindable, index in BINDABLE {
		if bindable == class {
			return index, true
		}
	}
	return 0, false
}

// Which classes this auction uses as a variable.
//
// A class binds when the auction leaves it open more than once (`1HS ... 2M`), or names "the other"
// one alongside any call of that class (`1H ... 2oM` -- the concrete 1H is what fixes it).
@(private = "file")
bound_classes :: proc(auction: Auction, out: []bids.Suits) -> []bids.Suits {
	open_uses, any_uses: [2]int
	other: [2]bool
	for index in 0 ..< flat.group_count(auction) {
		for bid in flat.group(auction, index) {
			slot, ok := bindable_slot(binding_class(bid))
			if !ok {
				continue
			}
			any_uses[slot] += 1
			if bids.is_other_class(bid.suit_class) {
				other[slot] = true
			} else if bids.suits_count(bid.suits) > 1 {
				open_uses[slot] += 1
			}
		}
	}
	// Fixed order rather than a map's: there are only two classes, and a deterministic list keeps
	// the generated variants in a stable order run to run.
	bindable := BINDABLE
	count := 0
	for slot in 0 ..< 2 {
		binds := any_uses[slot] > 0 && (open_uses[slot] > 1 || (other[slot] && any_uses[slot] > 1))
		if binds && count < len(out) {
			out[count] = bindable[slot]
			count += 1
		}
	}
	return out[:count]
}

// The one denomination of `class` the auction states outright, if any.
//
// Two different concrete calls of the same class (`1H` then `1S`) leave the variable genuinely
// ambiguous; returning none makes the caller fall back to the untightened auction rather than guess.
@(private = "file")
fixed_suit :: proc(auction: Auction, class: bids.Suits) -> bids.Suits {
	concrete := bids.NO_SUITS
	for index in 0 ..< flat.group_count(auction) {
		for bid in flat.group(auction, index) {
			if binding_class(bid) == class && bids.suits_count(bid.suits) == 1 {
				concrete |= bid.suits
			}
		}
	}
	return bids.suits_count(concrete) == 1 ? concrete : bids.NO_SUITS
}

@(private = "file")
Assignment :: struct {
	class:  bids.Suits,
	chosen: bids.Suits,
}

@(private = "file")
resolve_bid :: proc "contextless" (bid: bids.Bid, assignment: []Assignment) -> bids.Bid {
	class := binding_class(bid)
	for entry in assignment {
		if entry.class != class {
			continue
		}
		if class == bids.NO_SUITS || bids.suits_count(bid.suits) == 1 {
			return bid
		}
		out := bid
		out.suits = bids.is_other_class(bid.suit_class) ? class & ~entry.chosen : entry.chosen
		return out
	}
	return bid
}

// The concrete auctions an auction with correlated suit classes stands for -- the auction unchanged
// when nothing binds, which is the common case.
expand_correlated :: proc(auction: Auction, allocator := context.allocator) -> Variants {
	class_buffer: [2]bids.Suits
	classes := bound_classes(auction, class_buffer[:])

	variants := make(Variants, 0, 1, allocator)
	if len(classes) == 0 {
		append(&variants, flat.clone(auction, allocator))
		return variants
	}

	// One domain per bound class: the class's denominations, or the single one a spelled-out call
	// pinned it to.
	domains: [2][]bids.Suits
	domain_storage: [2][5]bids.Suits
	for class, slot in classes {
		fixed := fixed_suit(auction, class)
		has_other := false
		scan: for index in 0 ..< flat.group_count(auction) {
			for bid in flat.group(auction, index) {
				if binding_class(bid) == class && bids.is_other_class(bid.suit_class) {
					has_other = true
					break scan
				}
			}
		}
		if fixed != bids.NO_SUITS && has_other {
			domain_storage[slot][0] = fixed // a spelled-out call pins the variable
			domains[slot] = domain_storage[slot][:1]
			continue
		}
		count := 0
		for suit in bids.ALPHABETICAL {
			if suit & class != bids.NO_SUITS {
				domain_storage[slot][count] = suit
				count += 1
			}
		}
		domains[slot] = domain_storage[slot][:count]
	}

	assignment: [2]Assignment
	for class, slot in classes {
		assignment[slot].class = class
	}
	product(domains[:len(classes)], 0, assignment[:len(classes)], auction, &variants, allocator)

	if len(variants) == 0 {
		append(&variants, flat.clone(auction, allocator))
	}
	return variants
}

// `itertools.product` over the domains, in the same order, without materialising the whole
// cartesian product.
@(private = "file")
product :: proc(
	domains: [][]bids.Suits,
	depth: int,
	assignment: []Assignment,
	auction: Auction,
	variants: ^Variants,
	allocator: runtime.Allocator,
) {
	if depth == len(domains) {
		variant := flat.make_flat(bids.Bid, flat.group_count(auction), flat.item_count(auction), allocator)
		resolved: [bids.CALLS_MAX]bids.Bid
		for index in 0 ..< flat.group_count(auction) {
			position := flat.group(auction, index)
			count := min(len(position), len(resolved))
			for offset in 0 ..< count {
				resolved[offset] = resolve_bid(position[offset], assignment)
			}
			flat.push_group(&variant, resolved[:count])
		}
		append(variants, variant)
		return
	}
	for value in domains[depth] {
		assignment[depth].chosen = value
		product(domains, depth + 1, assignment, auction, variants, allocator)
	}
}

//
// Relative calls
//

// One way a relative token could resolve: the call it becomes, plus the previous position pinned to
// the single call it was measured from -- when that position is the one immediately before, which is
// the position `resolve_relative` rewrites.
@(private = "file")
Resolution :: struct {
	parent:     bids.Bid,
	has_parent: bool,
	call:       bids.Bid,
}

// The most resolutions one relative token can produce. `xstep` gives STEP_LIMIT, `!c+` gives seven
// levels per denomination, and a parent naming several calls multiplies by its own width.
RESOLUTIONS_MAX :: 64

// Replace `next` with the call it stands for: the cheapest bid above the position before it
// (`4HS = splinter` then `next = RKB` is 4S over 4H).
//
// Returns the auctions that produces. A parent naming several calls gives one auction per call, WITH
// THE PARENT PINNED -- 4H then 4S, or 4S then 4N, and never 4H then 4N, which no line of the table
// describes. A `next` whose parent is not a bid at all (`any`, prose) stays unresolved and so
// matches nothing: the auction never said which call it was.
//
// Run AFTER `expand_correlated`, so a parent whose suit class was bound is already concrete.
resolve_relative :: proc(auction: Auction, allocator := context.allocator) -> Variants {
	built := make(Variants, 0, 1, context.temp_allocator)
	append(&built, flat.make_flat(bids.Bid, flat.group_count(auction), 0, context.temp_allocator))

	relatives: [bids.CALLS_MAX]bids.Bid
	resolutions: [RESOLUTIONS_MAX]Resolution

	for index in 0 ..< flat.group_count(auction) {
		position := flat.group(auction, index)

		relative_count := 0
		for bid in position {
			if bids.is_relative(bid.kind) && relative_count < len(relatives) {
				relatives[relative_count] = bid
				relative_count += 1
			}
		}

		if relative_count == 0 || flat.is_empty(built[0]) {
			for &partial in built {
				flat.push_group(&partial, position)
			}
			continue
		}

		grown := make(Variants, 0, len(built), context.temp_allocator)
		for partial in built {
			resolved_any := false
			// `!c/!d` is two relative tokens at one position, so every one of them contributes its
			// resolutions.
			for relative in relatives[:relative_count] {
				for resolution in resolutions_of(relative, partial, resolutions[:]) {
					resolved_any = true
					call := resolution.call
					call.by_opponent = relative.by_opponent

					if !resolution.has_parent {
						// The call we measured from is further back than the previous position, so
						// there is nothing to pin here.
						next := flat.clone(partial, context.temp_allocator)
						flat.push_group(&next, []bids.Bid{call})
						append(&grown, next)
						continue
					}
					next := flat.make_flat(
						bids.Bid,
						flat.group_count(partial) + 1,
						flat.item_count(partial) + 2,
						context.temp_allocator,
					)
					flat.extend_prefix(&next, partial, flat.group_count(partial) - 1)
					flat.push_group(&next, []bids.Bid{resolution.parent})
					flat.push_group(&next, []bids.Bid{call})
					append(&grown, next)
				}
			}
			if !resolved_any {
				next := flat.clone(partial, context.temp_allocator)
				flat.push_group(&next, position) // unresolvable, keep as written
				append(&grown, next)
			}
		}
		built = grown
	}

	// The working copies live in the temp arena; the survivors are handed back in the caller's.
	out := make(Variants, 0, len(built), allocator)
	for partial in built {
		append(&out, flat.clone(partial, allocator))
	}
	return out
}

// Index of the last position holding an actual bid.
//
// Everything here measures "cheapest above" from a BID: a raise or a cue over partner's double is
// still legal, it just has to clear the last bid. Fails when the auction holds no bid at all.
@(private = "file")
last_bid_position :: proc(auction: Auction) -> (index: int, ok: bool) {
	for position := flat.group_count(auction) - 1; position >= 0; position -= 1 {
		for bid in flat.group(auction, position) {
			if bids.is_bid(bid) && bid.suits != bids.NO_SUITS {
				return position, true
			}
		}
	}
	return 0, false
}

// (pinned previous call, the call the token resolves to) for each call the previous position could
// have been.
@(private = "file")
resolutions_of :: proc(relative: bids.Bid, auction: Auction, out: []Resolution) -> []Resolution {
	source, found := last_bid_position(auction)
	if !found {
		return out[:0]
	}
	pin := source == flat.group_count(auction) - 1

	count := 0
	calls: [bids.CALLS_MAX]bids.Bid
	for previous in flat.group(auction, source) {
		for suit in bids.ALPHABETICAL {
			if suit & previous.suits == bids.NO_SUITS {
				continue
			}
			parent := previous
			parent.suits = suit
			parent.suit_class = .None

			if relative.kind == .Next {
				if call, ok := bids.next_call(parent); ok && count < len(out) {
					out[count] = Resolution{parent, pin, call}
					count += 1
				}
				continue
			}

			produced: []bids.Bid
			#partial switch relative.kind {
			case .Jump:
				produced = jumps_from(parent, relative.jump_levels, auction, calls[:])
			case .New:
				produced = in_suits(parent, unbid_suits(auction), relative.level, calls[:])
			case .Strain:
				// a denomination with no level: the simple (non-jump) bid in it
				produced = in_suits(parent, relative.suits, 0, calls[:])
			case .Strain_Any:
				// `!c+`: that strain at whatever level it takes, so every legal bid in it from the
				// cheapest upward
				cheapest: [bids.CALLS_MAX]bids.Bid
				written := 0
				for call in in_suits(parent, relative.suits, 0, cheapest[:]) {
					for level := call.level; level <= 7 && written < len(calls); level += 1 {
						raised := call
						raised.level = level
						calls[written] = raised
						written += 1
					}
				}
				produced = calls[:written]
			case .Raise:
				produced = raises_from(parent, auction, relative, calls[:])
			case .Slam:
				produced = slams_from(parent, auction, relative, calls[:])
			case .Next_Suit:
				produced = next_suit_from(parent, calls[:])
			case .Fourth_Suit:
				produced = fourth_suit_from(parent, auction, calls[:])
			case .Step:
				produced = steps_from(parent, relative.level, calls[:])
			case .Cue_Over:
				produced = in_suits(parent, rho_suits(parent, auction), relative.level, calls[:])
			case .Cue_Low, .Cue_High:
				produced = picked_cue(parent, auction, relative, calls[:])
			case:
				produced = cues_from(parent, auction, relative.level, calls[:])
			}

			for call in produced {
				if count >= len(out) {
					return out[:count]
				}
				out[count] = Resolution{parent, pin, call}
				count += 1
			}
		}
	}
	return out[:count]
}

// The denominations the auction pinned down to one suit, optionally only the opponents'. An
// unresolved `2M` names no single suit, so it neither counts as bid nor rules a suit out.
@(private = "file")
spoken_suits :: proc(auction: Auction, side: Side) -> bids.Suits {
	suits := bids.NO_SUITS
	for index in 0 ..< flat.group_count(auction) {
		for bid in flat.group(auction, index) {
			if !bids.is_bid(bid) || bids.suits_count(bid.suits) != 1 {
				continue
			}
			if !side_accepts(side, bid.by_opponent) {
				continue
			}
			suits |= bid.suits
		}
	}
	return suits
}

// Suits nobody has bid -- neither side. Notrump is not a suit.
@(private = "file")
unbid_suits :: proc(auction: Auction) -> bids.Suits {
	return bids.REAL_SUITS & ~spoken_suits(auction, .Either)
}

// The call in each of `suits`: at `level` when the token named one (`3new`), otherwise the cheapest
// available -- a simple bid, not a jump.
@(private = "file")
in_suits :: proc(parent: bids.Bid, suits: bids.Suits, level: u8, out: []bids.Bid) -> []bids.Bid {
	count := 0
	for suit in bids.ALPHABETICAL {
		if suit & suits == bids.NO_SUITS || count >= len(out) {
			continue
		}
		if level == 0 {
			if call, ok := bids.cheapest_call(parent, suit); ok {
				out[count] = call
				count += 1
			}
			continue
		}
		call := parent
		call.level = level
		call.suits = suit
		call.suit_class = .None
		call.jump_levels = 0
		out[count] = call
		count += 1
	}
	return out[:count]
}

// Support for the last suit partner bid.
//
// Partner's suit is the last bid on our own side of the table -- usually the call right before ours,
// but an opponent may have come in between. `jumpRaise` is one level above the simple raise, and
// `3raise` names the level outright.
@(private = "file")
raises_from :: proc(parent: bids.Bid, auction: Auction, token: bids.Bid, out: []bids.Bid) -> []bids.Bid {
	suits := partner_suits(auction, token.by_opponent, parent)
	if suits == bids.NO_SUITS {
		return out[:0]
	}
	raised := in_suits(parent, suits, token.level, out)
	if token.jump_levels == 0 {
		return raised
	}
	count := 0
	for call in raised {
		if call.level + token.jump_levels <= 7 {
			jumped := call
			jumped.level = call.level + token.jump_levels
			out[count] = jumped
			count += 1
		}
	}
	return out[:count]
}

// `slam`: the agreed suit -- the last one our side named -- at the slam level, 6 or 7. `6slam` says
// which.
@(private = "file")
slams_from :: proc(parent: bids.Bid, auction: Auction, token: bids.Bid, out: []bids.Bid) -> []bids.Bid {
	suits := partner_suits(auction, token.by_opponent, parent)
	count := 0
	for suit in bids.ALPHABETICAL {
		if suit & suits == bids.NO_SUITS {
			continue
		}
		cheapest, ok := bids.cheapest_call(parent, suit)
		if !ok {
			continue
		}
		if token.level != 0 {
			if token.level >= cheapest.level && count < len(out) {
				call := cheapest
				call.level = token.level
				out[count] = call
				count += 1
			}
			continue
		}
		for level in bids.SLAM_LEVELS {
			if level >= cheapest.level && count < len(out) {
				call := cheapest
				call.level = level
				out[count] = call
				count += 1
			}
		}
	}
	return out[:count]
}

// `nextSuit`: the next bid up that is a suit -- the cheapest call above, skipping notrump, since a
// `next` that lands on 3N is not one.
@(private = "file")
next_suit_from :: proc(parent: bids.Bid, out: []bids.Bid) -> []bids.Bid {
	candidates: [4]bids.Bid
	count := 0
	for suit in bids.ALPHABETICAL {
		if suit & bids.REAL_SUITS == bids.NO_SUITS {
			continue
		}
		if call, ok := bids.cheapest_call(parent, suit); ok {
			candidates[count] = call
			count += 1
		}
	}
	if lowest, ok := bids.lowest_call(candidates[:count]); ok && len(out) > 0 {
		out[0] = lowest
		return out[:1]
	}
	return out[:0]
}

// `4thSuit`: fourth-suit-forcing -- the one suit still unbid.
//
// Only resolvable when exactly one is left; with two or more the token is not describing anything
// the auction has pinned down.
@(private = "file")
fourth_suit_from :: proc(parent: bids.Bid, auction: Auction, out: []bids.Bid) -> []bids.Bid {
	unbid := unbid_suits(auction)
	if bids.suits_count(unbid) != 1 {
		return out[:0]
	}
	return in_suits(parent, unbid, 0, out)
}

// The suits of the last bid on the given side -- partner's, for our own tokens.
//
// When that bid is the one we are measuring from it has already been pinned to a single suit, so use
// it: `4HS` then `slam` is 6H over 4H or 6S over 4S, never 6S over 4H.
@(private = "file")
partner_suits :: proc(auction: Auction, by_opponent: bool, parent: bids.Bid) -> bids.Suits {
	last, has_bid := last_bid_position(auction)
	for index := flat.group_count(auction) - 1; index >= 0; index -= 1 {
		found := bids.NO_SUITS
		for bid in flat.group(auction, index) {
			if bids.is_bid(bid) && bid.by_opponent == by_opponent {
				found |= bid.suits
			}
		}
		if found == bids.NO_SUITS {
			continue
		}
		if parent.by_opponent == by_opponent && has_bid && index == last {
			return parent.suits & bids.ALL_SUITS
		}
		return found & bids.ALL_SUITS
	}
	return bids.NO_SUITS
}

// The step response(s) to an artificial ask.
//
// `1step` is one rung up the ladder, `2step` two. `xstep` is "a step response, however many the
// scheme has" -- the author's reading -- so it stands for the first STEP_LIMIT of them.
@(private = "file")
steps_from :: proc(parent: bids.Bid, step: u8, out: []bids.Bid) -> []bids.Bid {
	first := step != 0 ? step : 1
	last := step != 0 ? step : u8(bids.STEP_LIMIT)
	count := 0
	for n in first ..= last {
		if call, ok := bids.step_call(parent, n); ok && count < len(out) {
			out[count] = call
			count += 1
		}
	}
	return out[:count]
}

// The suit of the last call by the player on our immediate right, the one `cueOver` cues -- as
// opposed to `cue`, which is any of their suits.
//
// It is their LAST CALL that matters, not their last bid: if they doubled, there is nothing to cue
// over and the token stays unresolved. Notrump is dropped, there being no such thing as cueing
// notrump.
@(private = "file")
rho_suits :: proc(parent: bids.Bid, auction: Auction) -> bids.Suits {
	last_opponent := -1
	scan: for index := flat.group_count(auction) - 1; index >= 0; index -= 1 {
		for bid in flat.group(auction, index) {
			if bid.by_opponent {
				last_opponent = index
				break scan
			}
		}
	}
	if last_opponent < 0 {
		return bids.NO_SUITS
	}
	if last, has_bid := last_bid_position(auction); parent.by_opponent && has_bid && last == last_opponent {
		// their last call IS the bid we are measuring from, already pinned
		return parent.suits & bids.REAL_SUITS
	}
	suits := bids.NO_SUITS
	for bid in flat.group(auction, last_opponent) {
		if bids.is_bid(bid) {
			suits |= bid.suits
		}
	}
	return suits & bids.REAL_SUITS
}

// `cueLow` / `cueHi`: a cue of the lower- or higher-ranking of THEIR TWO SUITS. Only resolvable when
// the auction shows two opponent suits.
@(private = "file")
picked_cue :: proc(parent: bids.Bid, auction: Auction, token: bids.Bid, out: []bids.Bid) -> []bids.Bid {
	theirs := spoken_suits(auction, .Theirs)
	if bids.suits_count(theirs) < 2 {
		return out[:0]
	}
	picked := bids.NO_SUITS
	for suit in bids.ALPHABETICAL {
		if suit & theirs == bids.NO_SUITS {
			continue
		}
		if picked == bids.NO_SUITS {
			picked = suit
			continue
		}
		lower := bids.suit_rank(suit) < bids.suit_rank(picked)
		if token.kind == .Cue_Low ? lower : !lower {
			picked = suit
		}
	}
	if picked == bids.NO_SUITS {
		return out[:0]
	}
	return in_suits(parent, picked, token.level, out)
}

// A cue bid: their suit. Unqualified it is the LOWEST cue available, so with two opponent suits
// shown only the cheaper one counts.
@(private = "file")
cues_from :: proc(parent: bids.Bid, auction: Auction, level: u8, out: []bids.Bid) -> []bids.Bid {
	theirs := spoken_suits(auction, .Theirs)
	produced := in_suits(parent, theirs, level, out)
	if level != 0 || len(produced) == 0 {
		return produced
	}
	if lowest, ok := bids.lowest_call(produced); ok {
		out[0] = lowest
		return out[:1]
	}
	return produced
}

// Every call `jump` could be over `parent`: a jump in a NEW suit.
//
// A jump is `levels` above the cheapest bid available in that suit, never in notrump (a jump to 3N
// is a different animal), and never in a suit already bid. "Already bid" counts only calls the
// auction pinned down to one denomination, so an unresolved `2M` does not silently rule both majors
// out.
@(private = "file")
jumps_from :: proc(parent: bids.Bid, levels: u8, auction: Auction, out: []bids.Bid) -> []bids.Bid {
	spoken := spoken_suits(auction, .Either) | parent.suits
	count := 0
	for suit in bids.ALPHABETICAL {
		if suit & (bids.REAL_SUITS & ~spoken) == bids.NO_SUITS || count >= len(out) {
			continue
		}
		cheapest, ok := bids.cheapest_call(parent, suit)
		if !ok || cheapest.level + levels > 7 {
			continue
		}
		call := cheapest
		call.level = cheapest.level + levels
		out[count] = call
		count += 1
	}
	return out[:count]
}
