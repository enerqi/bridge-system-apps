/// The quiz rules. Ported from `apps/datastar-quiz/tests/test_engine.py` (by way of the Go port's
/// `engine_test.go`), which is itself asserted against the panel app's own `points` function.
///
/// The scoring is the one piece of this app where a silent one-off would look like a game-design
/// decision rather than a bug, so the expected numbers here are the reference implementation's,
/// arithmetic included -- `round(3 * 0.5) = 2` is half-to-even, not a typo.
module DsQuiz.Tests.EngineTests

open Expecto
open DsQuiz
open DsQuiz.Engine

let private questionOf (candidates: string array) (answerCandidate: string) : Question =
    { Candidates = candidates
      Answer = "the description"
      AnswerCandidate =
        if answerCandidate = "" && candidates.Length > 0 then
            candidates[0]
        else
            answerCandidate
      ChoiceType = Auctions }

let private toastTexts (outcome: Answered) : string array =
    outcome.Toasts |> Array.map (fun t -> t.Text)

let tests: Test =
    testList
        "engine"
        [ test "the seconds allowance matches the panel table" {
              // difficulty * secondsPerLevel[difficulty]
              for difficulty, want in
                  [ 4, 32.0
                    5, 35.0
                    6, 36.0
                    7, 35.0
                    8, 32.0
                    9, 36.0 ] do
                  Expect.equal (secondsForDifficulty difficulty) want $"difficulty {difficulty}"
          }

          test "the time bonus percentage never goes negative and never divides by zero" {
              Expect.equal (percentTimeLeft 0.0 10.0) 100 "a full clock"
              Expect.equal (percentTimeLeft 5.0 10.0) 50 "half the clock"
              Expect.equal (percentTimeLeft 12.0 10.0) 0 "over the allowance"
              Expect.equal (percentTimeLeft 1.0 0.0) 0 "no allowance is no bonus"
          }

          test "an unusable difficulty is the default, and a usable one is clamped" {
              Expect.equal (clampDifficulty (ValueSome 6)) 6 "in range"
              Expect.equal (clampDifficulty (ValueSome 99)) MaxDifficulty "above range"
              Expect.equal (clampDifficulty (ValueSome 1)) MinDifficulty "below range"
              Expect.equal (clampDifficulty ValueNone) InitialDifficulty "absent"
          }

          // The panel formula: one point per token across every candidate, +10% per streak step
          // (capped at doubling), plus the time bonus as a proportion of the same base.
          test "points are candidate lengths with two multipliers" {
              let question = questionOf [| "1C"; "1H"; "2N" |] ""
              let base' = 3

              let cases =
                  [ 0, 0, (base', 0, 0)
                    1, 0, (base', 0, 0) // a streak of one is not yet a bonus
                    2, 0, (base', 1, 0) // round(3 * 0.2) = 1
                    5, 0, (base', 2, 0) // round(3 * 0.5) = 2, half to even
                    12, 0, (base', 3, 0) // the multiplier caps at 1.0
                    0, 100, (base', 0, base') // a full clock doubles the base
                    0, 37, (base', 0, 1) // round(3 * 0.37) = 1
                    12, 100, (base', base', base') ]

              for streak, percentLeft, (wantBase, wantStreak, wantTime) in cases do
                  let got = scorePoints question streak percentLeft

                  Expect.equal
                      (got.FromCandidateLengths, got.FromStreakBonus, got.FromTimeBonus)
                      (wantBase, wantStreak, wantTime)
                      $"streak {streak}, {percentLeft}%%"

              // the `-->` joiner is not a token
              let joined = scorePoints (questionOf [| "1D --> 1S --> 3N"; "1C" |] "") 0 0
              Expect.equal joined.FromCandidateLengths 4 "the auction separator was counted"

              // no candidates, no points, no exception
              Expect.equal (scorePoints (questionOf Array.empty "") 5 100).Total 0 "an empty question"
          }

          test "a correct answer scores, streaks, and ends its instalments at the final total" {
              let question = questionOf [| "1C 1H 2N"; "1D 1S" |] "1C 1H 2N"

              let scored =
                  answer
                      Score.start
                      { Question = question
                        Candidate = "1C 1H 2N"
                        PercentLeft = 100
                        LadderMode = true
                        TargetOn = false
                        TargetPct = 70
                        LastCorrectPoints = 0
                        PointsGoal = PointsGoal }

              let outcome = scored.Outcome
              Expect.isTrue outcome.Correct "correct"
              Expect.equal scored.Score.Streak 1 "streak"
              Expect.equal scored.Score.QuestionsCorrect 1 "correct count"
              Expect.equal scored.Score.QuestionsAttempted 1 "attempted count"
              Expect.isGreaterThan scored.LastCorrectPoints 0 "the answer was worth something"

              Expect.equal
                  scored.Score.TotalPoints
                  scored.LastCorrectPoints
                  "the total is what this answer was worth"

              let texts = toastTexts outcome
              Expect.equal texts[0] "Correct!" "the first beat"
              Expect.stringStarts texts[1] "+" "the second beat shows the instalment"

              let lastShown =
                  outcome.Toasts
                  |> Array.fold
                      (fun shown toast ->
                          match toast.PointsAfter with
                          | ValueSome points -> points
                          | ValueNone -> shown
                      )
                      0

              Expect.equal lastShown scored.Score.TotalPoints "the last instalment shows the final score"
          }

          test "a wrong answer resets the streak and charges ladder mode" {
              let scored =
                  answer
                      { Score.start with TotalPoints = 100; Streak = 4 }
                      { Question = questionOf [| "1C"; "1D" |] "1D"
                        Candidate = "1C"
                        PercentLeft = 50
                        LadderMode = true
                        TargetOn = false
                        TargetPct = 70
                        LastCorrectPoints = 30
                        PointsGoal = PointsGoal }

              let outcome = scored.Outcome
              Expect.isFalse outcome.Correct "wrong"
              Expect.equal scored.Score.Streak 0 "the streak is gone"
              Expect.equal scored.Score.TotalPoints 70 "100 less the last correct answer's worth"
              Expect.equal scored.LastCorrectPoints 30 "it is what the NEXT wrong answer costs"

              let texts = String.concat "|" (toastTexts outcome)
              Expect.stringContains texts "Not quite" "the verdict"
              Expect.stringContains texts "Ladder mode: -30 points" "the charge"

              // the answer itself is revealed in the card, not read out in a toast the player waits
              // behind
              let pause = outcome.Toasts |> Array.sumBy (fun toast -> toast.Pause)
              Expect.isLessThan pause 2.0 "a wrong answer should be brief"
          }

          test "a zero score is not told it lost points" {
              let scored =
                  answer
                      Score.start
                      { Question = questionOf [| "1C"; "1D" |] "1D"
                        Candidate = "1C"
                        PercentLeft = 0
                        LadderMode = true
                        TargetOn = false
                        TargetPct = 70
                        LastCorrectPoints = 30
                        PointsGoal = PointsGoal }

              Expect.equal scored.Score.TotalPoints 0 "still zero"
              let texts = String.concat "|" (toastTexts scored.Outcome)
              Expect.isFalse (texts.Contains "Ladder mode") "a zero score should not be told it lost points"
          }

          test "milestones award skips once each, and crossing the goal collects them all" {
              let scored =
                  answer
                      { Score.start with
                          TotalPoints = PointsGoal - 1
                          QuestionsAttempted = 9
                          QuestionsCorrect = 9 }
                      { Question = questionOf [| "1C 1H 2N 3C 4D"; "1D" |] "1C 1H 2N 3C 4D"
                        Candidate = "1C 1H 2N 3C 4D"
                        PercentLeft = 100
                        LadderMode = false
                        TargetOn = false
                        TargetPct = 70
                        LastCorrectPoints = 0
                        PointsGoal = PointsGoal }

              let outcome = scored.Outcome
              Expect.equal outcome.AwardedSkips scoreMilestones.Length "every outstanding milestone"
              Expect.equal scored.Score.AvailableMilestones.Length 0 "none left uncollected"
              Expect.isTrue outcome.Completed "crossing the goal completes the quiz"

              // every skip beat is flagged, so the gauge sweep and its sound cannot be lost to a copy
              // edit of the words
              let flagged =
                  outcome.Toasts |> Array.filter (fun toast -> toast.AwardsSkip) |> Array.length

              Expect.equal flagged outcome.AwardedSkips "flagged beats match awarded skips"
          }

          test "the target percentage gates completion, and says why" {
              // 1 of 2 correct so far = 50%, below a 70% target
              let scored =
                  answer
                      { Score.start with
                          TotalPoints = PointsGoal
                          QuestionsAttempted = 2
                          QuestionsCorrect = 1 }
                      { Question = questionOf [| "1C"; "1D" |] "1C"
                        Candidate = "1C"
                        PercentLeft = 0
                        LadderMode = false
                        TargetOn = true
                        TargetPct = 70
                        LastCorrectPoints = 0
                        PointsGoal = PointsGoal }

              Expect.isFalse scored.Outcome.Completed "the target gates completion"

              Expect.stringContains
                  (String.concat "|" (toastTexts scored.Outcome))
                  "target score 70%"
                  "and says why"
          }

          test "a question draws distinct descriptions at every difficulty" {
              match Corpus.load () with
              | Error reason -> failtest reason
              | Ok corpus ->
                  let system = Corpus.Corpus.defaultSystem corpus

                  for difficulty in MinDifficulty..MaxDifficulty do
                      let question = newQuestion system.Auctions system.AllIndices difficulty
                      Expect.equal question.Candidates.Length difficulty $"difficulty {difficulty} candidates"
                      Expect.isGreaterThanOrEqual question.AnswerIndex 0 "the answer is among the candidates"

                      // only the DESCRIPTIONS are forced distinct; two auctions can repeat, but then
                      // they carry different descriptions and the question is still fair
                      if question.ChoiceType = Descriptions then
                          let distinct = question.Candidates |> Array.distinct |> Array.length
                          Expect.equal distinct difficulty "a description was offered twice"
          }

          test "prettifying a description spells the suit shorthand out" {
              Expect.equal (prettifyDescription "  5+ !c, 11-15  ") "5+ C, 11-15" "trimmed and spelled"
              Expect.equal (prettifyDescription "!c!d!h!s") "CDHS" "every suit"
              Expect.equal (prettifyDescription "no shorthand") "no shorthand" "left alone"
          } ]
