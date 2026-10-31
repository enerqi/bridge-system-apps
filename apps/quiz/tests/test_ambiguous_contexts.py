"""Auctions that mean different things in different sections of the notes.

`(1C)--1N` is "5S + 5 other" after a strong club and "~15--18" after a natural one. Shown bare, the
quiz asks the player to guess which section it means. `quiz.mark_ambiguous_contexts` gives each such
row the headings that tell it apart, and `quiz.generate_question` never puts one auction among the
choices twice (or two meanings of the asked auction among the descriptions).

    uv run --with pytest pytest apps/quiz/tests/test_ambiguous_contexts.py
"""

import random

import quiz  # first: it puts the bml tools on sys.path

import bml  # noqa: E402


def row(sequence: list[str], description: str, *headings: str) -> quiz.BidSequenceMeaning:
    headers = [quiz.Header(content_type=bml.ContentType.H2, text=text) for text in headings]
    return quiz.BidSequenceMeaning(
        sequence=sequence,
        description=description,
        _debug_headers_context=headers,
        _parsed_context_bids=[],
        _initial_sequence=sequence,
    )


def test_context_is_the_path_from_where_the_headings_part():
    strong = row(["(1C)", "1N"], "5S + 5 other", "Competitive", "Opponents open Strong 1C")
    natural = row(["(1C)", "1N"], "~15--18", "Competitive", "Opponents open 1C Natural", "(1C)--Overcall")
    quiz.mark_ambiguous_contexts([strong, natural])
    assert strong.context == "Opponents open Strong 1C"
    assert natural.context == "Opponents open 1C Natural › (1C)--Overcall"


def test_a_path_that_ends_early_gets_its_last_heading():
    summary = row(["1N", "2C"], "Stayman", "1NT Opening")
    detail = row(["1N", "2C"], "Stayman, promissory", "1NT Opening", "1N--2C")
    quiz.mark_ambiguous_contexts([summary, detail])
    assert summary.context == "1NT Opening"
    assert detail.context == "1N--2C"


def test_no_context_for_one_meaning_or_inseparable_headings():
    same_meaning = [row(["1H"], " 5 card Major ", "Summary"), row(["1H"], "5 card Major", "1H Opening")]
    same_path = [row(["(1C)", "2C"], "natural", "Overcalls"), row(["(1C)", "2C"], "majors", "Overcalls")]
    blank = [row(["1S"], "", "A"), row(["1S"], "5 card Major", "B")]
    rows = same_meaning + same_path + blank
    quiz.mark_ambiguous_contexts(rows)
    assert [r.context for r in rows] == [""] * len(rows)


def test_a_question_never_offers_one_auction_twice():
    rows = [row(["(1C)", "X"], f"meaning {i}", f"Section {i}") for i in range(6)]
    rows += [row(["1C", f"{level}S"], f"spades {level}", "Other") for level in range(1, 5)]
    quiz.mark_ambiguous_contexts(rows)
    random.seed(7)
    for _ in range(200):
        for choice_type in quiz.MultiChoiceType:
            question = quiz.generate_question(rows, 5, choice_type)
            auctions = [r.sequence for r in question._debug_bid_sequences]
            assert len(auctions) == len({tuple(a) for a in auctions})
            assert question.answer_candidate in question.candidates
            assert len(question.candidate_contexts) == len(question.candidates)


def test_the_context_travels_with_the_auction_shown():
    strong = row(["(1C)", "1N"], "5S + 5 other", "Opponents open Strong 1C")
    natural = row(["(1C)", "1N"], "~15--18", "Opponents open 1C Natural")
    quiz.mark_ambiguous_contexts([strong, natural])

    question = quiz.generate_question([strong], 1, quiz.MultiChoiceType.Descriptions)
    assert (question.answer, question.answer_context) == ("(1C) --> 1N", "Opponents open Strong 1C")

    question = quiz.generate_question([natural], 1, quiz.MultiChoiceType.Auctions)
    assert question.candidates == ["(1C) --> 1N"]
    assert question.candidate_contexts == ["Opponents open 1C Natural"]
    assert question.answer_context == ""


def test_a_small_pool_gives_fewer_choices_rather_than_hanging():
    rows = [row(["1C"], "clubs", "A"), row(["1C"], "strong", "B"), row(["1D"], "diamonds", "A")]
    question = quiz.generate_question(rows, 5, quiz.MultiChoiceType.Descriptions)
    assert len(question.candidates) == 2
    assert question.answer_candidate in question.candidates
