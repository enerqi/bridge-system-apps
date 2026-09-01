/// The call model, against the cases the python's own tests and the Go port's `bids_test.go`
/// pin -- the token spellings that actually appear in this corpus, plus the three that bit every
/// previous port: a bare `D` is a DOUBLE and not diamonds, `3X` is a level wildcard and not a
/// double, and `2D/2H` is ONE call rather than two.
module DsQuiz.Tests.BidsTests

open Expecto
open DsQuiz.Bids

let private call (token: string) : Call =
    match parseCall token with
    | ValueSome c -> c
    | ValueNone -> failtestf "%s did not parse" token

let private suitsOf (token: string) : string = Suits.chars (call token).Suits

let tests: Test =
    testList
        "bids"
        [ test "a plain bid is a level and one denomination" {
              let c = call "1D"
              Expect.equal c.Level 1 "level"
              Expect.equal c.Suits Suits.Diamonds "suits"
              Expect.equal c.Kind Bid "kind"
              Expect.isFalse c.ByOpponent "by opponent"
          }

          test "a multi-suit bid holds every denomination it allows" {
              Expect.equal (suitsOf "1HS") "HS" "1HS"
              Expect.equal (suitsOf "4CDHS") "CDHS" "4CDHS"
          }

          test "suit classes keep their case, and M is not m" {
              Expect.equal (suitsOf "2M") "HS" "2M is the majors"
              Expect.equal (suitsOf "3m") "CD" "3m is the minors"
              Expect.equal (call "2M").SuitClass MajorClass "2M names a class"
              Expect.equal (call "3m").SuitClass MinorClass "3m names a class"
              Expect.equal (call "2H").SuitClass NoClass "a named suit names no class"
          }

          test "the other-class tokens are variables over their class" {
              let om = call "3oM"
              Expect.equal om.Level 3 "level"
              Expect.equal om.SuitClass OtherMajor "class"
              Expect.equal (Suits.chars om.Suits) "HS" "membership is still the whole class"
              Expect.isTrue (isOtherClass om) "is an other-class token"
              Expect.equal (call "oM").Level 0 "a bare oM constrains the suit only"
          }

          test "a level wildcard is any denomination at that level" {
              Expect.equal (suitsOf "3*") "CDHNS" "3*"
              Expect.equal (suitsOf "3x") "CDHNS" "3x lowercase"
              Expect.equal (suitsOf "3X") "CDHNS" "3X uppercase"
              Expect.equal (call "3X").Kind Bid "a level wildcard is a bid, not a double"
          }

          test "a bare D is not diamonds, and not the double either" {
              // `!d` is diamonds; a bare `D` is excluded from the strain rule because the notation
              // means the double there -- but `DOUBLE_TOKENS` is {X, DBL} (bmlbids.py:78), so it
              // matches nothing and lands on `Other`. Both the python and the Go port do this, and
              // a port that "fixed" it either way would diverge from the corpus.
              Expect.equal (call "D").Kind Other "a bare D matches no rule"
              Expect.equal (call "X").Kind Double "X"
              Expect.equal (call "Dbl").Kind Double "Dbl"
              Expect.equal (call "XX").Kind Redouble "XX"
              Expect.equal (call "R").Kind Redouble "R"
              Expect.equal (call "Pass").Kind Pass "Pass"
              Expect.equal (call "P").Kind Pass "P"
          }

          test "!x shorthand and NT both normalise" {
              Expect.equal (suitsOf "1!h") "H" "1!h"
              Expect.equal (suitsOf "1!C") "C" "1!C"
              Expect.equal (suitsOf "1NT") "N" "1NT"
              Expect.equal (call "1NT").Level 1 "1NT level"
              // `!c` with no level is a STRAIN, and `!c+` is that strain at any level
              Expect.equal (call "!c").Kind Strain "!c"
              Expect.equal (call "!c+").Kind StrainAny "!c+"
              Expect.equal (suitsOf "!c") "C" "!c suits"
          }

          test "brackets mean the opponents made the call" {
              Expect.isTrue (call "(1S)").ByOpponent "(1S)"
              Expect.equal (call "(1S)").Suits Suits.Spades "(1S) suits"
              Expect.isTrue (call "(X)").ByOpponent "(X)"
              Expect.equal (call "(X)").Kind Double "(X) kind"
          }

          test "a markdown link unwraps to its call" {
              Expect.equal (call "[1D](#1C--1D)").Suits Suits.Diamonds "linked 1D"
              Expect.equal (call "[1D](#1C--1D)").Level 1 "linked level"
          }

          test "alternatives at one position merge when only the suit differs" {
              let merged = call "2D/2H"
              Expect.equal merged.Level 2 "level"
              Expect.equal (Suits.chars merged.Suits) "DH" "2D/2H is exactly 2DH"
              Expect.equal merged.Kind Bid "kind"
              // spanning levels cannot be one call
              Expect.equal (call "3S/4C").Kind Other "3S/4C has no single-call form"
              // ...but it is still a bid TOKEN, which is what keeps section context
              Expect.isTrue (isBidToken "3S/4C") "3S/4C is a bid token"
              Expect.equal (parseCallAlternatives "3S/4C").Length 2 "two alternatives"
          }

          test "brackets outside an alternation apply to every branch" {
              let calls = parseCallAlternatives "(2D/2H)"
              Expect.equal calls.Length 2 "two alternatives"
              Expect.isTrue (calls |> Array.forall (fun c -> c.ByOpponent)) "both by the opponents"
          }

          test "table words parse as their own kind rather than failing" {
              Expect.equal (call "any").Kind Any "any"
              Expect.equal (call "others").Kind Any "others"
              Expect.equal (call "(overcall)").Kind AnyBid "(overcall)"
              Expect.equal (call "(bid)").Kind AnyCall "(bid)"
              Expect.equal (call "game").Kind Game "game"
              Expect.equal (call "next").Kind Next "next"
              Expect.equal (call "cue").Kind Cue "cue"
              Expect.equal (call "cueLow").Kind CueLow "cueLow"
              Expect.equal (call "cueHi").Kind CueHigh "cueHi"
              Expect.equal (call "CueOver").Kind CueOver "CueOver"
              Expect.equal (call "new").Kind New "new"
              Expect.equal (call "newSuit").Kind New "newSuit"
              Expect.equal (call "2Y").Kind New "2Y"
              Expect.equal (call "4thSuit").Kind FourthSuit "4thSuit"
              Expect.equal (call "nextSuit").Kind NextSuit "nextSuit"
              Expect.equal (call "raise").Kind Raise "raise"
              Expect.equal (call "jumpRaise").JumpLevels 1 "jumpRaise is one level higher"
              Expect.equal (call "slam").Kind Slam "slam"
              Expect.equal (call "1step").Kind Step "1step"
              Expect.equal (call "step1").Level 1 "step1 carries which step"
              Expect.equal (call "xstep").Level 0 "xstep is any step"
              Expect.equal (call "jump").JumpLevels 1 "jump"
              Expect.equal (call "doubleJump").JumpLevels 2 "doubleJump"
              Expect.equal (call "2N+").Kind AtLeast "2N+"
              Expect.equal (call "waffle").Kind Other "an unrecognised token is carried, not fatal"
          }

          test "empty input is the one parse failure" {
              Expect.isTrue (parseCall "").IsNone "empty"
              Expect.isTrue (parseCall "   ").IsNone "blank"
              Expect.equal (parseCallAlternatives "").Length 0 "no alternatives"
          }

          test "nextCall walks the denominations then the level" {
              let next token =
                  match nextCall (call token) with
                  | ValueSome c -> string c.Level + Suits.chars c.Suits
                  | ValueNone -> "-"

              Expect.equal (next "1C") "1D" "1C -> 1D"
              Expect.equal (next "1S") "1N" "1S -> 1N"
              Expect.equal (next "1N") "2C" "1N -> 2C"
              Expect.equal (next "7N") "-" "the ceiling"
              Expect.equal (next "4HS") "-" "no single next step after a multi-suit bid"
              Expect.equal (next "Pass") "-" "not a bid"
          }

          test "stepCall counts the cheapest as step one" {
              match stepCall (call "4N") 1 with
              | ValueSome c -> Expect.equal (string c.Level + Suits.chars c.Suits) "5C" "step 1 over 4N"
              | ValueNone -> failtest "step 1 over 4N"

              match stepCall (call "4N") 3 with
              | ValueSome c -> Expect.equal (string c.Level + Suits.chars c.Suits) "5H" "step 3 over 4N"
              | ValueNone -> failtest "step 3 over 4N"
          }

          test "cheapestCall goes up a level only when it must" {
              let cheapest token suit =
                  match cheapestCall (call token) suit with
                  | ValueSome c -> string c.Level + Suits.chars c.Suits
                  | ValueNone -> "-"

              Expect.equal (cheapest "1C" Suits.Hearts) "1H" "hearts over 1C stays at one"
              Expect.equal (cheapest "1H" Suits.Clubs) "2C" "clubs over 1H needs two"
              Expect.equal (cheapest "1H" Suits.Hearts) "2H" "the same suit needs two"
              Expect.equal (cheapest "7N" Suits.Clubs) "-" "past the ceiling"
          }

          test "callsAtOrAbove enumerates upwards from the token" {
              let calls = callsAtOrAbove (call "2N+")
              Expect.equal calls[0].Level 2 "starts at the token's level"
              Expect.equal calls[0].Suits Suits.Notrump "starts at the token's denomination"
              Expect.equal calls[1].Level 3 "then the next level"
              Expect.equal calls[1].Suits Suits.Clubs "starting at clubs"
              Expect.equal calls.Length (1 + 5 * 5) "2N, then every call from 3C to 7N"
          }

          test "callLessThan is strict, and false for anything ambiguous" {
              Expect.isTrue (callLessThan "1C" "1D") "1C < 1D"
              Expect.isTrue (callLessThan "1S" "2C") "1S < 2C"
              Expect.isFalse (callLessThan "1D" "1C") "not the other way"
              Expect.isFalse (callLessThan "1C" "1C") "not reflexive"
              Expect.isTrue (callLessThan "1C" "2HS") "below every denomination it allows"
              Expect.isFalse (callLessThan "1HS" "1S") "1H is below 1S but 1S is not"
              Expect.isFalse (callLessThan "Pass" "1C") "non-bids compare false"
          }

          test "bidTokens keeps multi-suit bids and drops the prose" {
              Expect.equal (bidTokens [| "1C (Pass) 1HS"; "X" |]) [| "1C"; "1HS" |] "bid tokens"
              Expect.equal (parseCalls [| "1C (Pass) 1H" |]).Length 3 "every call in the string"
          }

          test "the denomination set behaves like python's frozenset" {
              Expect.equal (Suits.chars Suits.all) "CDHNS" "alphabetical, as python sorts"
              Expect.equal (Suits.count Suits.majors) 2 "two majors"
              Expect.equal (Suits.single Suits.Hearts) Suits.Hearts "a single denomination"
              Expect.equal (Suits.single Suits.majors) Suits.Empty "not a single denomination"
              Expect.isTrue (Suits.subsetOf Suits.all Suits.majors) "majors are a subset of all"
              Expect.isFalse (Suits.subsetOf Suits.minors Suits.majors) "majors are not minors"
              Expect.equal (Suits.rank Suits.Notrump) 5 "notrump is highest"

              Expect.equal
                  (Suits.inRankOrder Suits.all |> Array.map Suits.toChar)
                  [| 'C'
                     'D'
                     'H'
                     'S'
                     'N' |]
                  "auction order"
          } ]
