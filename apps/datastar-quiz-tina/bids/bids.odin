// The canonical model of a bridge call: a port of the bml tools' `bmlbids.py`, which the python
// quiz, the html renderers and the Odin markup implementation all share.
//
// A call is written the way bml writes it:
//
//	1D 2H 3N      a bid: level 1-7 plus one or more denominations, C D H S N
//	1HS           a multi-suit bid, meaning "1H or 1S"
//	2M 3m         suit classes: M = a major {H,S}, m = a minor {C,D}. These are the one
//	              place case is significant
//	3* 3x         any denomination at that level
//	oM 3oM        "the other major" -- a variable, resolved against an earlier call
//	[1D](#1C--1D) a call written as a markdown link to its own section
//	1!h           `!x` suit shorthand, as used in .bml source
//	1NT           `NT` is accepted and normalised to `N`
//	Pass P        pass          X Dbl    double        XX Rdbl R   redouble
//	(1S) (X)      brackets mean the opponents made this call
//	2D/2H 3S/4C   alternatives at ONE position
//
// # Where the allocation story starts
//
// `Bid` is six bytes, comparable, and has no pointer in it. The python holds a frozen dataclass with
// two `frozenset`s and two `str`s; the Go port shrank the sets to a bitmask but kept `Kind` and
// `SuitClass` as `string`, which is 32 of its 40 bytes -- two pointers and two lengths carrying what
// is really a pair of small enums. The Rust port made the same call this one does.
//
// That matters because of how many there are: preparing the swedish system for filtering produces
// roughly 400,000, held for the life of the process. 16 MB in Go, ~2.4 MB here. It is also the
// difference between a matcher that chases pointers and one that walks an array.
//
// Parsing allocates nothing. Token normalisation writes into a caller-supplied stack buffer rather
// than building strings, because `parse_call` runs on every token of a 7,600-auction corpus at boot
// AND on every keystroke of a filter box at request time, where the handler scratch arena is a few
// kilobytes and shared with everything else.
package bids

// A denomination. Notrump is a denomination but not a suit, and several routines below care about
// the difference and say so.
//
// Declaration order fixes the bit values (C=1, D=2, H=4, S=8, N=16), matching the other ports. It is
// NOT the order things are enumerated in -- see ALPHABETICAL.
Suit :: enum u8 {
	Clubs,
	Diamonds,
	Hearts,
	Spades,
	Notrump,
}

Suits :: distinct bit_set[Suit;u8]

CLUBS :: Suits{.Clubs}
DIAMONDS :: Suits{.Diamonds}
HEARTS :: Suits{.Hearts}
SPADES :: Suits{.Spades}
NOTRUMP :: Suits{.Notrump}

MAJORS :: Suits{.Hearts, .Spades}
MINORS :: Suits{.Clubs, .Diamonds}
ALL_SUITS :: Suits{.Clubs, .Diamonds, .Hearts, .Spades, .Notrump}
// The four real suits: what `new`, `jump` and the cue tokens range over.
REAL_SUITS :: Suits{.Clubs, .Diamonds, .Hearts, .Spades}
NO_SUITS :: Suits{}

// Alphabetical, which is the order python's `sorted(frozenset)` produces -- kept so generated
// variants come out in the same order as the reference implementation's. Note that N sorts between
// H and S, which is why this is a table rather than the enum's own order.
ALPHABETICAL :: [5]Suits{CLUBS, DIAMONDS, HEARTS, NOTRUMP, SPADES}

suits_count :: #force_inline proc "contextless" (suits: Suits) -> int {
	return card(suits)
}

// Ordering of the denominations within a level; notrump is highest. Zero for a set that is not
// exactly one denomination.
suit_rank :: proc "contextless" (suits: Suits) -> u8 {
	switch suits {
	case CLUBS:
		return 1
	case DIAMONDS:
		return 2
	case HEARTS:
		return 3
	case SPADES:
		return 4
	case NOTRUMP:
		return 5
	}
	return 0
}

suit_from_rank :: proc "contextless" (rank: u8) -> Suits {
	switch rank {
	case 1:
		return CLUBS
	case 2:
		return DIAMONDS
	case 3:
		return HEARTS
	case 4:
		return SPADES
	case 5:
		return NOTRUMP
	}
	return NO_SUITS
}

suit_from_char :: proc "contextless" (ch: u8) -> Suits {
	switch ch {
	case 'C':
		return CLUBS
	case 'D':
		return DIAMONDS
	case 'H':
		return HEARTS
	case 'S':
		return SPADES
	case 'N':
		return NOTRUMP
	}
	return NO_SUITS
}

suit_to_char :: proc "contextless" (suits: Suits) -> u8 {
	switch suits {
	case CLUBS:
		return 'C'
	case DIAMONDS:
		return 'D'
	case HEARTS:
		return 'H'
	case SPADES:
		return 'S'
	case NOTRUMP:
		return 'N'
	}
	return '?'
}

// What a token is. The python and the Go both carry this as a string; here it is one byte, which is
// most of why a Bid fits in six.
Kind :: enum u8 {
	// prose, or a token this model does not cover. First, so it is the zero value.
	Other,
	Bid,
	Pass,
	Double,
	Redouble,
	// `any` / `other(s)`: whatever is called here, constraining nothing at all
	Any,
	// `(overcall)` / `(higher)`: any *bid*, so not a pass and not a double
	Any_Bid,
	// `(bid)`: the same but doubles count too -- anything except a pass
	Any_Call,
	// `game`: 3N, or a major game, or a minor game
	Game,
	// `2N+`: that call or anything above it
	At_Least,
	// --- the relative kinds, whose call has to be worked out from the auction so far ---
	Next,
	Jump,
	Cue,
	Cue_Over,
	Cue_Low,
	Cue_High,
	New,
	Step,
	Raise,
	// a denomination with no level: the simple (non-jump) bid in that strain
	Strain,
	// `!c+`: that strain at whatever level it takes
	Strain_Any,
	Slam,
	Next_Suit,
	Fourth_Suit,
}

RELATIVE_KINDS :: bit_set[Kind] {
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
	.Fourth_Suit,
}

// Whether this token's call has to be resolved against the auction so far.
is_relative :: #force_inline proc "contextless" (kind: Kind) -> bool {
	return kind in RELATIVE_KINDS
}

// Which suit *class* a token named, when it named one rather than listing denominations.
Suit_Class :: enum u8 {
	None,
	Major, // `M`
	Minor, // `m`
	Other_Major, // `oM`
	Other_Minor, // `om`
}

// `oM`/`om`: the complement, within its class, of the bound suit.
is_other_class :: #force_inline proc "contextless" (class: Suit_Class) -> bool {
	return class == .Other_Major || class == .Other_Minor
}

// The denominations this class ranges over, or none when the token named no class.
class_suits_of :: proc "contextless" (class: Suit_Class) -> Suits {
	switch class {
	case .Major, .Other_Major:
		return MAJORS
	case .Minor, .Other_Minor:
		return MINORS
	case .None:
		return NO_SUITS
	}
	return NO_SUITS
}

// One call. `suits` holds every denomination the token allows, so a plain `1H` is {H} and a
// multi-suit `1HS` is {H, S}.
Bid :: struct {
	// 1..=7, or 0 for pass/double/redouble/other. `Step` uses it for which step, counting from 1.
	level:       u8,
	suits:       Suits,
	kind:        Kind,
	by_opponent: bool,
	suit_class:  Suit_Class,
	// For `Jump`/`Raise`: how many levels above the cheapest available bid.
	jump_levels: u8,
}

#assert(size_of(Bid) == 6)

is_bid :: #force_inline proc "contextless" (bid: Bid) -> bool {
	return bid.kind == .Bid
}

// The denominations this token's class ranges over ({H,S} for any of M/oM), or its own suits when
// it named no class.
class_suits :: proc "contextless" (bid: Bid) -> Suits {
	if bid.suit_class == .None {
		return bid.suits
	}
	return class_suits_of(bid.suit_class)
}

plain :: proc "contextless" (kind: Kind, by_opponent: bool) -> Bid {
	return Bid{kind = kind, by_opponent = by_opponent}
}

// How many step responses `xstep` stands for -- the corpus's own EKB rows describe five ("5th step
// = 2 KC + a void") before leaving the ladder with `6x`.
STEP_LIMIT :: 5

// The levels `slam` stands for when the token does not say.
SLAM_LEVELS :: [2]u8{6, 7}

// `/` separates alternatives at a single position: `2D/2H` is one call, not two.
ALT_SEP :: '/'

// `game` is a game contract: 3N, or a major game, or a minor game.
Game_Call :: struct {
	level: u8,
	suits: Suits,
}

GAME_CALLS :: [5]Game_Call{{3, NOTRUMP}, {4, HEARTS}, {4, SPADES}, {5, CLUBS}, {5, DIAMONDS}}

// The longest token normalisation handles. Real call tokens are a handful of characters; this is
// generous, and anything longer is prose, which parses to `.Other` anyway.
TOKEN_BUFFER_MAX :: 64

// The most alternatives one position can hold (`2D/2H/3C/...`). The corpus's widest is two.
ALTERNATIVES_MAX :: 8
