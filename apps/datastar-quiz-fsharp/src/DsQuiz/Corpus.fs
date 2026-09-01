/// The `.bml` corpus and the bidding-tree filter over it.
///
/// The python app imports `apps/quiz/quiz.py` and parses the notes itself. This port does not: writing
/// a fourth BML parser (after the python one, the Odin `bridge-markup` and the Go port's non-attempt)
/// is weeks of work and is not what the comparison is about. Instead the parsed corpus is EXPORTED from
/// the python app by `apps/datastar-quiz/tools/export_corpus.py` and embedded here, so every
/// implementation provably draws questions from the same auctions -- `just export-corpus` asserts the
/// md5s.
///
/// What is NOT exported is the filter: the matcher is ported (see `BidFilter`), because that is where
/// the CPU goes and a comparison that skips it is not a comparison.
///
/// THE JSON IS READ BY HAND, with `Utf8JsonReader`, and that is not premature cleverness: F# has no
/// Roslyn source generators, so `System.Text.Json`'s source generation -- which emits a C# partial
/// class -- is simply unavailable here. The alternative is the reflection-based serialiser, which
/// carries trim warnings and would shut the Native AOT column (P6) before it opened. A hand-walked
/// reader is ~100 lines, allocates only the strings it keeps, and needs no attributes on anything.
module DsQuiz.Corpus

open System
open System.Collections.Generic
open System.IO
open System.Reflection
open System.Text.Json

open DsQuiz.BidFilter
open DsQuiz.BidFilter.Pattern

/// A quiz flavour: which bml system it draws on, and how it is presented.
[<NoEquality; NoComparison>]
type Variant =
    { Key: string
      Title: string
      BMLFile: string
      SystemNotesURL: string }

/// One bidding sequence and what it means -- exactly the public fields of the python
/// `quiz.BidSequenceMeaning`.
[<NoEquality; NoComparison>]
type Auction = { Sequence: string array; Description: string }

/// What a filter string selects, and whether the caller should adopt it.
[<StructuralEquality; NoComparison>]
type FilterStatus =
    /// no patterns: everything matches
    | FilterAll
    /// usable
    | FilterOk
    /// nothing resolved to a pattern or a topic
    | FilterError
    /// matched, but too few auctions to build the hardest question
    | FilterTooFew

let statusText (status: FilterStatus) : string =
    match status with
    | FilterAll -> "all"
    | FilterOk -> "ok"
    | FilterError -> "error"
    | FilterTooFew -> "too_few"

/// What a filter string *would* select. Asking never commits it.
///
/// `Hits` is INDICES into `System.Auctions`, not the auctions themselves -- 4 bytes a hit, shared
/// between every session that asked the same question, and it makes the golden digest (a sha256 over
/// the matching indices) a direct read rather than a reconstruction. The Go port stores the auctions
/// and pays 14.6 MB of live heap for it; the Rust port stores indices, and so does this.
[<NoEquality; NoComparison>]
type FilterCheck = { Status: FilterStatus; Hits: int array; Parsed: Topics.ParsedFilter }

let usable (check: FilterCheck) : bool = check.Status = FilterOk

// ---------------------------------------------------------------------------------------------
// the filter memo
// ---------------------------------------------------------------------------------------------

/// How many distinct filters to remember.
///
/// 256 (as in the python) is comfortably larger than the topic list plus the prefixes a typist
/// produces, and small enough that it cannot become a memory leak: the text is user input, so an
/// unbounded cache would be a way to grow the process without limit. Each entry holds an index array,
/// and the "everything matches" branch stores the SHARED array rather than a copy.
[<Literal>]
let FilterCacheSize = 256

[<Struct; NoComparison>]
type FilterKey = { Text: string; MinHits: int }

/// An LRU over `checkFilter`, which is the app's most expensive routine and is called per keystroke.
/// The python measures 15.8ms for `1C` and 43ms for a topic against 7,627 auctions, and an 87.6% hit
/// rate under load; both preview routes missed their latency targets without it.
///
/// THE KEY IS THE NORMALISED TEXT, which costs nothing extra and is exact rather than approximate:
/// `parseFilter` starts by normalising, so ` 1C-1D `, `1C  --  1D` and `1C--1D` already produce
/// identical results. Case is deliberately NOT folded in on top of that: `m` is the minors and `M` the
/// majors, so a case-insensitive key would answer `1m` with the majors. `1c` and `1C` cost two entries
/// and agree.
///
/// Nothing here can go stale: every input is fixed for the life of the process (the corpus is embedded,
/// the topics are loaded once) and every value is read-only. `Gate` is the one lock -- a dictionary
/// plus a recency list cannot be updated atomically without it.
[<NoEquality; NoComparison>]
type FilterCache =
    { Gate: obj
      Size: int
      Entries: Dictionary<FilterKey, LinkedListNode<KeyValuePair<FilterKey, FilterCheck>>>
      Order: LinkedList<KeyValuePair<FilterKey, FilterCheck>>
      mutable Hits: int64
      mutable Misses: int64 }

/// The memo's counters, for the debug panel and for reporting the hit rate under load.
[<Struct>]
type CacheInfo =
    { CacheHits: int64
      CacheMisses: int64
      Count: int
      MaxSize: int }

[<RequireQualifiedAccess>]
module FilterCache =

    let create (size: int) : FilterCache =
        { Gate = obj ()
          Size = size
          Entries = Dictionary()
          Order = LinkedList()
          Hits = 0L
          Misses = 0L }

    let tryGet (key: FilterKey) (cache: FilterCache) : FilterCheck voption =
        lock
            cache.Gate
            (fun () ->
                match cache.Entries.TryGetValue key with
                | true, node ->
                    cache.Hits <- cache.Hits + 1L
                    cache.Order.Remove node
                    cache.Order.AddFirst node
                    ValueSome node.Value.Value
                | _ ->
                    cache.Misses <- cache.Misses + 1L
                    ValueNone
            )

    let put (key: FilterKey) (value: FilterCheck) (cache: FilterCache) : unit =
        lock
            cache.Gate
            (fun () ->
                match cache.Entries.TryGetValue key with
                | true, node ->
                    node.Value <- KeyValuePair(key, value)
                    cache.Order.Remove node
                    cache.Order.AddFirst node
                | _ ->
                    cache.Entries[key] <- cache.Order.AddFirst(KeyValuePair(key, value))

                    while cache.Order.Count > cache.Size do
                        let oldest = cache.Order.Last
                        cache.Order.RemoveLast()
                        cache.Entries.Remove oldest.Value.Key |> ignore
            )

    let info (cache: FilterCache) : CacheInfo =
        lock
            cache.Gate
            (fun () ->
                { CacheHits = cache.Hits
                  CacheMisses = cache.Misses
                  Count = cache.Order.Count
                  MaxSize = cache.Size }
            )

    let clear (cache: FilterCache) : unit =
        lock
            cache.Gate
            (fun () ->
                cache.Entries.Clear()
                cache.Order.Clear()
                cache.Hits <- 0L
                cache.Misses <- 0L
            )

// ---------------------------------------------------------------------------------------------
// a loaded system
// ---------------------------------------------------------------------------------------------

/// One loaded variant: its auctions, the same auctions pre-parsed for filtering, and its topics.
///
/// Built once at boot and read concurrently forever after. The arrays are never written to again, so
/// they are handed out as they are -- `AllIndices` in particular is the "everything matches" answer,
/// allocated once and shared by every unfiltered session rather than rebuilt per request.
[<NoEquality; NoComparison>]
type System =
    {
        Variant: Variant
        Auctions: Auction array
        /// canonical parsed bids per auction, index-aligned with `Auctions`. Filtering is then prefix
        /// comparison, which is what makes validating on every keystroke cheap enough to do at all.
        Prepared: Variants array
        Topics: Topics.TopicSet
        AllIndices: int array
        Cache: FilterCache
    }

[<RequireQualifiedAccess>]
module System =

    let private checkFilterUncached (normalised: string) (minHits: int) (system: System) : FilterCheck =
        let parsed = Topics.parseFilter normalised system.Topics

        if parsed.Patterns.Length = 0 then
            { Status = (if parsed.Errors.Length > 0 then FilterError else FilterAll)
              Hits = system.AllIndices
              Parsed = parsed }
        else
            let hits = ResizeArray<int>()

            for i in 0 .. system.Prepared.Length - 1 do
                if Matcher.bidsMatchAny system.Prepared[i] parsed.Patterns then
                    hits.Add i

            { Status = (if hits.Count < minHits then FilterTooFew else FilterOk)
              Hits = hits.ToArray()
              Parsed = parsed }

    /// The port of the python `corpus.check_filter`.
    ///
    /// Used both to validate as the user types and to apply on commit, so the preview can never
    /// disagree with the result. Statuses other than `FilterOk` mean the caller should fall back to the
    /// whole system -- question generation needs `minHits` distinct auctions to build the hardest
    /// question.
    let checkFilter (text: string) (minHits: int) (system: System) : FilterCheck =
        let key = { Text = normaliseFilterText text; MinHits = minHits }

        match FilterCache.tryGet key system.Cache with
        | ValueSome cached -> cached
        | ValueNone ->
            let check = checkFilterUncached key.Text minHits system
            FilterCache.put key check system.Cache
            check

// ---------------------------------------------------------------------------------------------
// the exported JSON
// ---------------------------------------------------------------------------------------------

/// What one variant's file holds, as the reader fills it.
type private Exported =
    { mutable VariantKey: string
      mutable Title: string
      mutable BMLFile: string
      mutable SystemNotesURL: string
      Auctions: ResizeArray<Auction>
      Topics: ResizeArray<Topics.Topic> }

let private readStringArray (reader: byref<Utf8JsonReader>) : string array =
    let items = ResizeArray<string>()

    if reader.TokenType = JsonTokenType.StartArray then
        while reader.Read() && reader.TokenType <> JsonTokenType.EndArray do
            if reader.TokenType = JsonTokenType.String then
                items.Add(reader.GetString())

    items.ToArray()

let private readAuction (reader: byref<Utf8JsonReader>) : Auction =
    let mutable sequence = Array.empty
    let mutable description = ""

    while reader.Read() && reader.TokenType <> JsonTokenType.EndObject do
        if reader.TokenType = JsonTokenType.PropertyName then
            let name = reader.GetString()
            reader.Read() |> ignore

            match name with
            | "sequence" -> sequence <- readStringArray &reader
            | "description" -> description <- reader.GetString()
            | _ -> reader.Skip()

    { Sequence = sequence; Description = description }

let private readTopic (reader: byref<Utf8JsonReader>) : Topics.Topic =
    let mutable name = ""
    let mutable patterns = Array.empty
    let mutable description = ""

    while reader.Read() && reader.TokenType <> JsonTokenType.EndObject do
        if reader.TokenType = JsonTokenType.PropertyName then
            let field = reader.GetString()
            reader.Read() |> ignore

            match field with
            | "name" -> name <- reader.GetString()
            | "patterns" -> patterns <- readStringArray &reader
            | "description" -> description <- reader.GetString()
            | _ -> reader.Skip()

    { Name = name; Patterns = patterns; Description = description }

let private readExported (utf8: byte array) : Exported =
    let mutable reader = Utf8JsonReader(ReadOnlySpan utf8)

    let payload =
        { VariantKey = ""
          Title = ""
          BMLFile = ""
          SystemNotesURL = ""
          Auctions = ResizeArray()
          Topics = ResizeArray() }

    while reader.Read() do
        if reader.TokenType = JsonTokenType.PropertyName then
            let name = reader.GetString()
            reader.Read() |> ignore

            match name with
            | "variant" -> payload.VariantKey <- reader.GetString()
            | "title" -> payload.Title <- reader.GetString()
            | "bml_file" -> payload.BMLFile <- reader.GetString()
            | "system_notes_url" -> payload.SystemNotesURL <- reader.GetString()
            | "auctions" ->
                while reader.Read() && reader.TokenType <> JsonTokenType.EndArray do
                    if reader.TokenType = JsonTokenType.StartObject then
                        payload.Auctions.Add(readAuction &reader)
            | "topics" ->
                while reader.Read() && reader.TokenType <> JsonTokenType.EndArray do
                    if reader.TokenType = JsonTokenType.StartObject then
                        payload.Topics.Add(readTopic &reader)
            | _ -> reader.Skip()

    payload

// ---------------------------------------------------------------------------------------------
// loading
// ---------------------------------------------------------------------------------------------

/// The order the variants are declared in, which is the order boot walks them. `squad` is the default
/// -- `?swedish` picks the other.
let variantOrder = [| "squad"; "swedish" |]

/// What a bare URL means.
[<Literal>]
let DefaultVariantKey = "squad"

/// Names a directory of `<variant>.json` files to load INSTEAD of the embedded copy. For regenerating
/// and diffing without a rebuild; unset in any normal run.
[<Literal>]
let CorpusDirEnv = "DSQUIZ_CORPUS_DIR"

let private readVariantBytes (key: string) : Result<byte array, string> =
    let name = key + ".json"

    match Environment.GetEnvironmentVariable CorpusDirEnv with
    | null
    | "" ->
        match Assembly.GetExecutingAssembly().GetManifestResourceStream("corpus/" + name) with
        | null -> Error $"corpus {name}: not embedded in this build"
        | stream ->
            use stream = stream
            use buffer = new MemoryStream()
            stream.CopyTo buffer
            Ok(buffer.ToArray())
    | dir ->
        let path = Path.Combine(dir, name)

        if File.Exists path then
            Ok(File.ReadAllBytes path)
        else
            Error $"corpus {name}: {path} does not exist"

let private loadVariant (key: string) : Result<System, string> =
    match readVariantBytes key with
    | Error reason -> Error reason
    | Ok utf8 ->
        let payload = readExported utf8

        if payload.Auctions.Count = 0 then
            Error $"corpus {key}.json: no auctions"
        else
            let auctions = payload.Auctions.ToArray()

            Ok
                { Variant =
                    { Key = payload.VariantKey
                      Title = payload.Title
                      BMLFile = payload.BMLFile
                      SystemNotesURL = payload.SystemNotesURL }
                  Auctions = auctions
                  Prepared = Matcher.prepareSequenceBids (auctions |> Array.map (fun a -> a.Sequence))
                  Topics = Topics.TopicSet.create (payload.Topics.ToArray())
                  AllIndices = Array.init auctions.Length id
                  Cache = FilterCache.create FilterCacheSize }

/// Every variant, loaded and pre-parsed for filtering.
[<NoEquality; NoComparison>]
type Corpus = { Systems: Dictionary<string, System> }

[<RequireQualifiedAccess>]
module Corpus =

    /// The loaded system for a variant key, or `ValueNone` for a key this build does not have.
    ///
    /// Tolerant on purpose: the key may have come from a browser's stored "which system was I on", and
    /// a renamed variant should hand the player the default rather than an error.
    let tryGet (key: string) (corpus: Corpus) : System voption =
        match corpus.Systems.TryGetValue key with
        | true, system -> ValueSome system
        | _ -> ValueNone

    /// The system a bare URL means.
    let defaultSystem (corpus: Corpus) : System = corpus.Systems[DefaultVariantKey]

    /// The variant a query string explicitly asks for, or `ValueNone` if it names none.
    ///
    /// Distinct from `variantSwitchForQuery` on purpose: an unrelated query (`?debug`) must not be read
    /// as "switch me back to the default", or a swedish session would flip to squad on the next odd
    /// link.
    let requestedVariant (query: string) (corpus: Corpus) : System voption =
        // the query is short and this runs per page load, so `Contains ... OrdinalIgnoreCase` beats
        // lowercasing the whole string first
        let names (key: string) =
            query.Contains(key, StringComparison.OrdinalIgnoreCase)

        if names "swedish" then tryGet "swedish" corpus
        elif names "squad" then tryGet "squad" corpus
        else ValueNone

    /// What an *existing* session should switch to, or `ValueNone` to keep the variant it has.
    ///
    /// Three cases, and the middle one is the whole point:
    ///
    ///   - names a variant (`?swedish`, `?squad`) -> that variant, as `requestedVariant`;
    ///   - **no query at all** -> the default. The bare URL is the one people share and link to, so it
    ///     has to mean "take me home"; without this a `?swedish` session is stuck forever, because
    ///     nothing in the UI says the way back is a query string nobody remembers;
    ///   - a non-empty query naming no variant (`?debug`) -> `ValueNone`, keep what the session has.
    let variantSwitchForQuery (query: string) (corpus: Corpus) : System voption =
        if query = "" then
            ValueSome(defaultSystem corpus)
        else
            requestedVariant query corpus

/// Loads every variant.
///
/// Called AT STARTUP, not on whoever asks first, and there is deliberately no lazy path to fall back
/// to. The python app learned this the expensive way: the yappi profile caught `load_bid_tables` (1.3s)
/// plus `prepare_sequence_bids` (4.3s) landing inside a REQUEST, on the first visitor to open the
/// second system. Here the parse is already done -- only the preparation is left -- but it is still
/// work that belongs to the process rather than to a player.
///
/// `Error` names the file and what was wrong with it: a corpus this build cannot read is a startup
/// failure, not something to discover on the first request.
let load () : Result<Corpus, string> =
    let systems =
        Dictionary<string, System>(variantOrder.Length, StringComparer.Ordinal)

    let mutable failure = ValueNone

    for key in variantOrder do
        if failure.IsNone then
            match loadVariant key with
            | Ok system -> systems[key] <- system
            | Error reason -> failure <- ValueSome reason

    match failure with
    | ValueSome reason -> Error reason
    | ValueNone -> Ok { Systems = systems }
