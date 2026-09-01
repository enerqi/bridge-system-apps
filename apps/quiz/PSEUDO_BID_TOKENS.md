# Pseudo-bid tokens in auctions

Bid tables do not only contain calls. They contain words that *describe* a call
relative to the auction so far — `next`, `jump`, `cue`, `new`, `raise`, `slam`
— and words that stand for a whole class of calls — `any`, `(overcall)`,
`game`. This file records what each one means, how the quiz resolves it, and
what is still unresolved.

It started as a plan for work not yet done; most of it is now a reference. The
semantics below are the system author's own readings, settled one at a time.

**State:** 73 of 61,264 auction positions (0.12%) are still unmatchable, across
32 spellings. It was 1,763 (2.9%) when this began.

---

## 1. How resolution works

Two layers, deliberately separated:

- **`bmlbids.py`** (in the bml tools repo) parses a *token*. It records which
  rule applies and any level the token named — nothing that needs an auction.
  Every kind is listed in §3.
- **`bidfilter.py`** *resolves* the auction-dependent ones, because it is the
  only place that has the auction.

The resolving rule, in one sentence: **do not make the matcher stateful —
expand an auction into the concrete auctions it stands for, and match if any of
them does.**

`prepare_auction(sequence)` is the whole pipeline:

```
parse_sequence_positions   one entry per position, each the calls it allows
significant_positions      drop opponent passes
expand_correlated          bind suit classes: 1HS … 2M is one major, twice
resolve_relative           replace next/jump/cue/new/raise/… with real calls
```

Four properties worth preserving:

1. **Pinning.** Whatever a resolution depended on is fixed in that variant. So
   `1HS … 2M` cannot match 1H-then-2S, `4HS … next` cannot match 4H-then-4N,
   and `4HS … slam` cannot match 4H-then-6S. Each was a bug before it was a
   property; the cross-pairing cases in `test_bidfilter.py` guard them.
2. **Measure from the last *bid*, not the last call.** A raise or a new suit
   over partner's double still only has to clear whatever was actually bid.
   `CueOver` is the deliberate exception — it reads their last *call*, because
   if the player on our right doubled there is nothing to cue over.
3. **Unresolvable means unmatched.** Never a wildcard fallback. Matching too
   much invents auctions the tables never described; matching too little only
   hides rows that were already hidden.
4. **Auction-state resolution stays out of `bmlbids`.** That module is a token
   model shared with the html renderers, which have no auction.

---

## 2. Corpus notation settled along the way

Changes made to the `.bml` sources, all small:

| was | now | why |
|---|---|---|
| `1HS--3x/4x`, `1H--1S--3N/4x` (headers) | `3*/4*`, `3N/4*` | one wildcard spelling in headers; `x` still works everywhere |
| `!c/!d = pass/correct, any level` (×3) | `!c+/!d+` | a bare strain is the *simple* bid; the `+` says any level, which is what those rows mean |

Author's own edit during the same work: `More` → `any`.

Notation that could still be tidied, no code needed:

- `(1C)--1HS--(higher)`, `(1D)--1HS--(higher)`, `(1H)--1S--(higher)` — three
  section headers where `(higher)` carries a bound. Renaming to `(2C+)` makes
  them resolve exactly; the third already says "2 level+ bids" in its text.

---

## 3. Token reference

Everything `bmlbids.parse_call` understands beyond a plain `1H`. "Resolved by"
names the `bidfilter` helper where the auction is involved.

### Denominations and classes

| token | means | notes |
|---|---|---|
| `1HS`, `4CDHS` | multi-suit: any of those denominations | matching is set overlap |
| `2M`, `3m` | a major / a minor at that level | `Bid.suit_class` records the class |
| `oM`, `3oM`, `om` | *the other* major / minor | bound against the auction, `expand_correlated` |
| `3*`, `3x` | any denomination at that level | tables write `x`, headers `*` |
| `NT`, `N`, `m`, `M`, `major`, `minor`, `!c` | that strain, **no level** — the simple, non-jump bid in it | `_in_suits` |
| `!c+`, `m+`, `M+` | that strain at **any** level | the pass/correct sense |
| `2N+`, `2x+`, `2S+` | that call or anything higher | enumerated by `calls_at_or_above` |
| `2D/2H`, `3S/4C` | alternatives at **one** position | never two consecutive calls |
| `[1D](#1C--1D)` | a call written as a markdown link | `unwrap_link` |

A bare `D` is the **double**, not diamonds — the guard reads the token as
written, so `!d` is still diamonds.

### Relative to the auction

| token | means | resolved by |
|---|---|---|
| `next` | the cheapest bid above the previous call — the relay step | `next_call` |
| `1step`, `step1`, `xstep` | rung *n* of an artificial ask's ladder; `xstep` is any of the first `STEP_LIMIT` (5) | `_steps_from` |
| `jump`, `jumpNew`, `doubleJump` | a jump in a **new suit**, never to notrump | `_jumps_from` |
| `new`, `3new`, `newSuit`, `suit`, `1y`, `2Y`, `(otherSuit)` | a suit **neither side** has bid; unqualified, at the cheapest level | `_unbid_suits` |
| `4thSuit` | the one suit still unbid — only when exactly one is left | `_fourth_suit_from` |
| `nextSuit` | the next bid up that is a *suit*, skipping notrump | `_next_suit_from` |
| `cue`, `3cue` | a bid in a suit the opponents bid; unqualified, the **lowest available** cue | `_cues_from` |
| `CueOver` | cue the player on our immediate **right** — their last call | `_rho_suits` |
| `cueLow`, `cueHi`, `cueHigh` | the lower- / higher-**ranking** of their two suits | `_picked_cue` |
| `raise`, `3raise`, `jumpRaise` | support the last suit **our side** bid — partner's, since calls alternate | `_raises_from` |
| `slam`, `6slam` | the agreed suit at the slam level, 6 or 7 | `_slams_from` |

### Catch-alls

| token | means | kind |
|---|---|---|
| `any`, `(any)`, `other`, `others` | anything at all | `any` |
| `(overcall)`, `(higher)` | any *bid* — not a pass, not a double | `anybid` |
| `(bid)` | anything except a pass (doubles count) | `anycall` |
| `game` | a game contract: 3N, 4H, 4S, 5C, 5D | expanded to those five |

`other`/`others` reading as a plain catch-all rather than "not my sibling rows"
is the author's call, and it is what kept most of this work out of the tree.
`(higher)` likewise: the calls worth naming — `(X)`, `(1N)`, `(2C)` — have
their own sections beside it.

---

## 4. Two parser bugs fixed on the way (not pseudo-bids)

### `1H2C` — `Node.bidrepr` mangled compound auctions (195 positions)

The old code stripped the dashes, then re-found calls with a `\d[A-Za-z]+`
regex and rejoined them: `(1CD)--1H--2C` glued to `(1CD)1H2C`, `1C--P--1H`
swallowed the pass into `1CP (P) 1H`, `2N+` truncated to `2N`, and the
alternation `3S/4C` was rewritten into a two-call auction.

`bml.bid_representation` now splits on the separator *first*. A single dash is
ambiguous — a separator in `1c-2d-3d`, a word joiner in `new-suit` — so it
splits only when every part is call-shaped. 436 bid tokens changed.

### `(a)`–`(d)` prose lists parsed as bid rows (50 positions)

```
3C = artificial, multi-meaning.
(a) minimum (semi)balanced no singleton
(d) void hand, any strength
```

Two changes in `bml.py`, both needed: a bracketed **single letter** is a call
only for `P X R D`, case-sensitively; and the description-continuation rule no
longer requires indentation, since these sit in the same column as the bid they
explain. Bracketed *words* (`(any)`, `(cue)`, `(higher)`) stay pseudo-bid rows.

---

## 5. What is left — 73 positions, 32 spellings

Grouped by what each would need. None of it is a family any more.

**The sibling rows** — `simple`, `nonJump`, `break` (9). Stated against the
other rows of the same bid table, which `quiz.collect_bid_table_auctions`
discards. `break` is a transfer declined, and needs no system knowledge to find
the completion, because the tables write it as a sibling:

```
2C = !d transfer, good 8+ hcp
    break = short !ds, e.g. 2N
    2D = complete, nothing special      <- the completion, an explicit sibling
```

Either carry the siblings onto `BidSequenceMeaning`, or resolve during the tree
walk into an explicit "any call except these" position — the second keeps
`bidfilter` free of tree concepts. Both need an **exclusion** shape, which no
`BidPattern` field can express today.

**Pinning a position that is not the previous call** — `6void` (3), "6 of the
suit the earlier `4x/5x` EKB bid showed". The auction holds that suit, but the
token naming it is a wildcard several positions back, and `resolve_relative`
only pins the position immediately before. A general "pin position N" would
serve this and remove the one known looseness in `raise` (partner's multi-suit
bid, with an opponent call since).

**System knowledge the calls do not carry** — `6trump`/`7trump` (8) need the
agreed trump suit. `cueLow`/`cueHi` are implemented but resolve nothing in the
corpus, because there the opponents' two suits come from a *conventional* bid
(`1C--(2!c) = two suiter, two known (e.g. majors)`) and which two they are is
not in the calls. Recommendation: leave unmatched rather than guess.

**Compound words** stacking two rules — `jumpcue` (3), `NewCue` (2),
`lowCue`/`highCue` (4), `CueResp` (2).

**Level-prefixed catch-alls** — `6other` (5), `(2other)` (4), `4other` (2),
`6higher` (5). Presumably "any other 6-level call": a level filter on the `any`
kind, small once confirmed.

**Half-resolved** — `(raise/rebid)` (16) matches raises and misses rebids;
`rebid` (a player's *own* previous suit, two calls back on that side) is
unmodelled. It is not in the count above, because the `raise` branch resolves.

**Odd one** — `P...X` (2), which looks like a compound auction with an ellipsis
rather than a pseudo-bid.

---

## 6. Regenerating the census

```shell
uv run python - <<'EOF'
import sys, collections; sys.path.insert(0, "apps/quiz")
import quiz, bmlbids
def invisible(tok):
    alts = bmlbids.parse_call_alternatives(tok)
    return (not alts) or all(a.kind == "other" for a in alts)
c = collections.Counter()
for f in ["bidding-system.bml", "scanian-natural.bml", "squad-system.bml",
          "youth-improvements.bml", "alternatives.bml", "competitive-bidding.bml"]:
    t = quiz.load_bid_tables(f); quiz.prettify_bid_table_nodes(t)
    for a in quiz.collect_bid_table_auctions(t):
        for element in a.sequence:
            for tok in str(element).split():
                if invisible(tok):
                    c[tok] += 1
print(sum(c.values()), "positions;", len(c), "distinct"); print(c.most_common(25))
EOF
```

Read it with care: a token like `(raise/rebid)` counts as resolved because one
branch is.

---

## 7. Non-goals

- **Do not** map an unresolvable token to a wildcard as a fallback (§1.3).
- **Do not** put auction-state resolution in `bmlbids` (§1.4).
- **Do not** teach the model what a *conventional* bid shows. Everything here
  is derivable from the calls themselves; `cueLow` over `(2!c)` and `6trump`
  are where that line falls, and they stay unmatched.

---

## 8. Reviewing a golden diff (read this before changing the parser)

Changes here move what the parser produces for thousands of rows, and the bml
snapshots (`bml/tests/snapshot_parse.py`) report the drift as one flat diff. A
positional `unified_diff` is the wrong tool: once line counts shift it pairs
unrelated rows and invents "changes" that never happened — which is exactly how
the first cut of the `bidrepr` fix looked plausible while quietly mangling
`new-suit` into two calls.

Compare **keyed by the thing that did not change**. For `bidrepr`, that is the
`bid` token it came from:

```python
import re, collections
rx = re.compile(r"bid=('(?:[^']*)') bidrepr='([^']*)'")

def vals(text):
    c = collections.Counter()
    for line in text.splitlines():
        m = rx.search(line)
        if m:
            c[(m.group(1), m.group(2))] += 1
    return c

old, new = vals(open(golden).read()), vals(serialize(label))
changed = collections.defaultdict(lambda: [None, None])
for (bid, rep), _ in (old - new).items():
    changed[bid][0] = rep
for (bid, rep), _ in (new - old).items():
    changed[bid][1] = rep
```

Then bucket `changed` by the *shape* of the transformation (whitespace only,
prefix preserved, one value vanished) and print a few samples per bucket. A few
hundred rows collapse into four or five buckets, and anything landing in the
"other — review" bucket is where the real bugs are.

Also: the corpus moves under the goldens, because the `.bml` files are edited
continuously. Drift is often an authoring change, not a parser change. Check by
parsing a pristine tree (`git archive HEAD | tar -x -C tmpdir`, then
`BRIDGE_DIR=tmpdir`) rather than touching the working tree, and do not
regenerate goldens over in-flight edits.

---

## 9. Testing

- Token parsing: `bml/tests/test_bmlbids.py`.
- Resolution and matching: `apps/quiz/tests/test_bidfilter.py`, in the style of
  `test_raise_supports_partners_last_suit` — assert both what now matches *and*
  what must not, including the cross-pairing cases.
- Corpus behaviour: `apps/quiz/tests/test_quiz_context.py`, naming a real
  section, as `test_alternation_section_does_not_invent_a_call` does.
- Parser output: the bml golden snapshots (§8).

```shell
uv run pytest apps/quiz/tests -q                       # in the bridge repo
uv run --with pytest python -m pytest tests -q         # in ~/dev/bml
```
