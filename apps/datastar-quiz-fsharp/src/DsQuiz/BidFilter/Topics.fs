/// Topics -- named bundles of patterns -- and the interpretation of a whole filter string.
/// Ported from the Go port's `internal/bidfilter/filter.go`.
///
/// The python reads topics from a per-variant toml beside `apps/quiz/bidfilter.py` (`topics_file_for`,
/// whole-file replacement, no merging). Here they arrive with the exported corpus, already filtered
/// to the bml system they apply to and already in file order -- which is the order the picker renders
/// them in.
module DsQuiz.BidFilter.Topics

open System
open System.Collections.Generic

open DsQuiz.BidFilter.Pattern

/// A named bundle of patterns; an auction matches the topic if it matches any one of them.
[<NoEquality; NoComparison>]
type Topic = { Name: string; Patterns: string array; Description: string }

/// A variant's topic list, in file order, with the parsed patterns alongside.
///
/// Built once at boot and never written to again, so the fields are plain and public: nothing is
/// hidden, and `TopicSet` below is the module of functions over them.
[<NoEquality; NoComparison>]
type TopicSet =
    {
        /// the topics, in file order -- which is the order the picker renders
        List: Topic array
        /// parsed patterns per topic, index-aligned with `List`
        Parsed: Pattern array array
        /// the normalised names in file order, so a fuzzy match scans deterministically
        NormOrder: string array
        /// normalised name -> index into `List`
        ByNorm: Dictionary<string, int>
    }

/// Folds a topic name for comparison the same way user input is normalised, so a name containing a
/// dash still matches what the user typed.
let normName (name: string) : string =
    (normaliseFilterText name).ToLowerInvariant()

[<RequireQualifiedAccess>]
module TopicSet =

    let empty =
        { List = Array.empty
          Parsed = Array.empty
          NormOrder = Array.empty
          ByNorm = Dictionary<string, int>(StringComparer.Ordinal) }

    /// Parses and indexes a variant's topics. PARSING HAPPENS ONCE AT LOAD, and a topic whose patterns
    /// do not parse is dropped rather than breaking the whole list, exactly as `load_topics` does.
    let create (list: Topic array) : TopicSet =
        let kept = ResizeArray<Topic> list.Length
        let parsed = ResizeArray<Pattern array> list.Length
        let order = ResizeArray<string> list.Length
        let byNorm = Dictionary<string, int>(list.Length, StringComparer.Ordinal)

        for topic in list do
            if topic.Patterns.Length > 0 then
                let patterns = Array.zeroCreate<Pattern> topic.Patterns.Length
                let mutable ok = true

                for i in 0 .. topic.Patterns.Length - 1 do
                    if ok then
                        match parsePattern topic.Patterns[i] with
                        | Ok pattern -> patterns[i] <- pattern
                        | Error _ -> ok <- false

                if ok then
                    let norm = normName topic.Name

                    if not (byNorm.ContainsKey norm) then
                        order.Add norm

                    byNorm[norm] <- kept.Count
                    kept.Add topic
                    parsed.Add patterns

        { List = kept.ToArray()
          Parsed = parsed.ToArray()
          NormOrder = order.ToArray()
          ByNorm = byNorm }

    let count (topics: TopicSet) : int = topics.List.Length

    /// Resolves free-form text to a single topic index, or -1.
    ///
    /// Tried in order, each ignoring case and superfluous whitespace: exact name, then (unless fuzzy is
    /// off) unique prefix, then unique substring. AMBIGUOUS INPUT RESOLVES TO -1 so the caller can fall
    /// back to treating it as a bid pattern.
    let matchName (text: string) (fuzzy: bool) (topics: TopicSet) : int =
        let target = normName text

        if target = "" then
            -1
        else
            match topics.ByNorm.TryGetValue target with
            | true, index -> index
            | _ when not fuzzy -> -1
            | _ ->
                // prefix first, then substring: the same order the python and the Go port try, and the
                // reason typing part of a topic name and pressing Enter selects it
                let uniqueBy (test: string -> bool) =
                    let mutable hit = -1
                    let mutable found = 0

                    for norm in topics.NormOrder do
                        if test norm then
                            hit <- topics.ByNorm[norm]
                            found <- found + 1

                    if found = 1 then hit else -1

                match uniqueBy (fun norm -> norm.StartsWith(target, StringComparison.Ordinal)) with
                | -1 -> uniqueBy (fun norm -> norm.Contains(target, StringComparison.Ordinal))
                | hit -> hit

/// The result of interpreting a filter string.
///
/// `Patterns` is the flat OR list actually matched against; `Entries` records what each
/// comma-separated entry resolved to, and `CanonicalText` is the input rewritten with resolved topic
/// names (what the input box should show after the user commits).
[<NoEquality; NoComparison>]
type ParsedFilter =
    { Patterns: Pattern array
      Entries: string array
      TopicNames: string array
      CanonicalText: string
      Errors: string array }

/// Interprets a whole filter string: `topic name, 1D-1M, 1H-(X)`.
///
/// Each entry is resolved in this order: an exact topic name, then a bid pattern, then a fuzzy topic
/// name (unique prefix or substring -- this is what makes typing part of a topic and pressing Enter
/// select it). PATTERNS ARE TRIED BEFORE THE FUZZY STEP so a valid pattern is never hijacked by a
/// topic that happens to contain it in its name.
///
/// Unresolvable entries land in `Errors` and are skipped; the remaining entries still filter, so one
/// typo does not discard the rest.
let parseFilter (text: string) (topics: TopicSet) : ParsedFilter =
    let entries = splitEntries text
    let patterns = ResizeArray<Pattern>()
    let canonical = ResizeArray<string>()
    let topicNames = ResizeArray<string>()
    let errors = ResizeArray<string>()

    for entry in entries do
        let exact = TopicSet.matchName entry false topics

        let index =
            if exact >= 0 then
                exact
            else
                match parsePattern entry with
                | Ok pattern ->
                    patterns.Add pattern
                    canonical.Add(canonicalPatternText entry)
                    // -2: resolved as a pattern, so neither a topic nor an error
                    -2
                | Error _ -> TopicSet.matchName entry true topics

        if index >= 0 then
            patterns.AddRange topics.Parsed[index]
            canonical.Add topics.List[index].Name
            topicNames.Add topics.List[index].Name
        elif index = -1 then
            errors.Add entry

    { Patterns = patterns.ToArray()
      Entries = entries
      TopicNames = topicNames.ToArray()
      CanonicalText = String.Join(", ", canonical)
      Errors = errors.ToArray() }
