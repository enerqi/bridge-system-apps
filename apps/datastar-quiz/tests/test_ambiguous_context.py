"""The section an ambiguous auction comes from, shown with the auction.

`(1C)--1N` means one thing after a strong club and another after a natural one; the quiz carries the
headings that tell them apart (`quiz.mark_ambiguous_contexts`) and the page shows them under the
auction, on the question and on the reveal alike.
"""

from __future__ import annotations

import corpus
import render
import state

Q = corpus.quiz


def _session_with(question: Q.Question) -> state.Session:
    session = state.new_session(corpus.DEFAULT_VARIANT)
    session.question = question
    return session


def test_the_asked_auction_carries_its_section():
    session = _session_with(
        Q.Question(
            candidates=["5S + 5 other", "majors"],
            answer="(1C) --> 1N",
            answer_candidate="5S + 5 other",
            choice_type=Q.MultiChoiceType.Descriptions,
            _debug_bid_sequences=[],
            answer_context="Opponents open Strong 1C",
            candidate_contexts=["", ""],
        )
    )
    html = render.quiz_body(session)
    assert '<small class="quiz-context">Opponents open Strong 1C</small></p>' in html

    session.awaiting_next = True
    session.wrong_index = 1
    assert '<small class="quiz-context">Opponents open Strong 1C</small></p>' in render.quiz_body(session)


def test_each_ambiguous_auction_choice_carries_its_section():
    session = _session_with(
        Q.Question(
            candidates=["(1C) --> 1N", "1H"],
            answer="~15--18",
            answer_candidate="(1C) --> 1N",
            choice_type=Q.MultiChoiceType.Auctions,
            _debug_bid_sequences=[],
            candidate_contexts=["Opponents open 1C Natural", ""],
        )
    )
    html = render.quiz_body(session)
    assert html.count('class="quiz-context"') == 1
    assert "Opponents open 1C Natural</small></span>" in html


def test_a_question_without_contexts_renders_none():
    session = state.new_session(corpus.DEFAULT_VARIANT)
    session.question.answer_context = ""
    session.question.candidate_contexts = [""] * len(session.question.candidates)
    assert "quiz-context" not in render.quiz_body(session)


def test_the_corpus_marks_the_opponents_strong_club():
    meanings = {
        seq.context
        for seq in corpus.bid_sequences("bidding-system.bml")
        if seq.sequence == ["(1C)", "1N"] and seq.description.strip()
    }
    assert "Opponents open Strong 1C" in meanings
