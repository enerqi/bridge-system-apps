/// Escaping, the suit glyphs and the auction text -- the same cases the Rust port's `tests/render.rs`
/// asserts, so the two agree character for character on the strings that end up in a patch.
module DsQuiz.Tests.RenderTests

open System

open Expecto
open DsQuiz.Render

let private separator: string = String('⁣', 4) + "‣" + String('⁣', 4)

let tests: Test =
    testList
        "render"
        [ test "the escaper emits the same entities as the jinja and Go templates" {
              // NOT `&#60;` (Askama) and NOT `&quot;` (most encoders): these are the spellings the
              // reference implementations write, so the payloads can be diffed
              Expect.equal (Escape.escape "a<b&c\"d") "a&lt;b&amp;c&#34;d" "entities"
              Expect.equal (Escape.escape "it's") "it&#39;s" "apostrophe"
              Expect.equal (Escape.escape ">") "&gt;" "greater than"
              Expect.equal (Escape.escape "plain text") "plain text" "nothing to do"
          }

          test "suits are coloured and markup in the input is escaped first" {
              let got = Escape.suits "1♠ <b>"
              Expect.stringContains got "<span class=\"scolor\">♠</span>" "the glyph is coloured"
              Expect.isFalse (got.Contains "<b>") "markup in the input was not escaped"
              Expect.equal (Escape.suits "no glyphs") "no glyphs" "nothing to colour"
          }

          test "the auction text turns letters into glyphs and keeps 1NT alone" {
              let cases =
                  [ "1C", "1♣"
                    // `N` becomes `NT`, but an already-spelled `1NT` is left alone -- the negative
                    // lookahead the python's regex needs and this port hand-writes
                    "1N", "1NT"
                    "1NT", "1NT"
                    "2HS", "2♥♠"
                    "1D --> 1H", $"1♦ {separator} 1♥"
                    "1C (Pass) 1H", $"1♣ {separator} 1♥"
                    "[1D](#1C--1D)", "1♦"
                    "!c and !s", "♣ and ♠" ]

              for input, want in cases do
                  Expect.equal (Auction.emojiTextAuction input) want $"emojiTextAuction {input}"
          } ]
