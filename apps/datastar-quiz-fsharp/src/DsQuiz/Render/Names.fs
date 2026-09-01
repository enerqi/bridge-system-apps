/// DATASTAR ATTRIBUTE-KEY NAMING, and it is the one transform in this app that fails SILENTLY.
///
/// HTML lowercases attribute names, so `data-bind:filterText` reaches datastar as
/// `data-bind:filtertext` and binds a *different* signal from the `filterText` the server seeded.
/// Datastar's answer is to write attribute keys in kebab-case and convert: `bind.ts` runs the key
/// through `camel`, which is `kebab` then de-dashing. `kebab` also splits letter/digit boundaries, so
/// `1c_opening` becomes the signal `1COpening` -- which is why a slug cannot simply be assumed to
/// survive the trip. These mirror that transform, so the markup and the server agree on the name.
///
/// There are tests for it in `apps/datastar-quiz/tests/test_signal_names.py`, the load harness
/// carries its own copy (`apps/dsquiz-perf/common/datastar.py`), and every port carries another --
/// five implementations of one five-line transform, because getting it wrong is silent. The goldens
/// in `testdata/topic_names.json` are the shared check.
module DsQuiz.Render.Names

open System
open System.Collections.Concurrent
open System.Text.RegularExpressions

open DsQuiz.BidFilter
open DsQuiz.Corpus

let private re pattern options : System.Text.RegularExpressions.Regex =
    Regex(pattern, RegexOptions.Compiled ||| options)

let private kebabUpperRunRE = re @"([A-Z]+)([A-Z][a-z])" RegexOptions.None
let private kebabLowerUpRE = re @"([a-z0-9])([A-Z])" RegexOptions.None
let private kebabAlphaNumRE = re @"([a-z])([0-9]+)" RegexOptions.IgnoreCase
let private kebabNumAlphaRE = re @"([0-9]+)([a-z])" RegexOptions.IgnoreCase
let private kebabSpaceRE = re @"[\s_]+" RegexOptions.None
let private camelDashRE = re @"-(.)" RegexOptions.None
let private slugStripRE = re @"[^0-9A-Za-z\s_-]+" RegexOptions.None
let private slugDashRunRE = re @"-{2,}" RegexOptions.None

/// datastar's `kebab`, which is what an attribute key goes through.
let datastarKebab (text: string) : string =
    let out = kebabUpperRunRE.Replace(text, "$1-$2")
    let out = kebabLowerUpRE.Replace(out, "$1-$2")
    let out = kebabAlphaNumRE.Replace(out, "$1-$2")
    let out = kebabNumAlphaRE.Replace(out, "$1-$2")
    let out = kebabSpaceRE.Replace(out, "-")
    out.ToLowerInvariant()

/// The name a kebab attribute key actually writes into the signal store.
let datastarCamel (text: string) : string =
    camelDashRE.Replace(datastarKebab text, (fun (m: Match) -> m.Groups[1].Value.ToUpperInvariant()))

/// The attribute form of a topic name: `data-bind:topics.<slug>`.
let topicSlug (name: string) : string =
    let slug = datastarKebab (slugStripRE.Replace(name, " "))
    let slug = (slugDashRunRE.Replace(slug, "-")).Trim '-'
    if slug = "" then "topic" else slug

/// The name that same binding writes into the signal store.
let topicSignalKey (name: string) : string = datastarCamel (topicSlug name)

/// One row of the topics picker.
///
/// `Bind` is the WHOLE attribute, precomputed: an attribute *name* cannot be interpolated, in a
/// template or in a DSL, so `data-bind:topics.<slug>` has to be assembled before it is written.
[<NoEquality; NoComparison>]
type TopicChoice =
    { Name: string
      Slug: string
      Key: string
      Description: string
      Bind: string }

/// Built ONCE PER VARIANT, not once per render.
///
/// The python memoises these four functions because the yappi profile of a 60-user minute counted
/// 37,868 calls to `datastar_kebab`, 25,236 to `topic_slug` and 12,632 to `topic_signal_key` -- five
/// regex passes each, recomputed on every render, for values that are pure functions of a topic name
/// that never changes within a process. The same fix applies here, one level up: the whole derived
/// row set is computed once per system and read lock-free thereafter.
let private choices =
    ConcurrentDictionary<string, TopicChoice array>(StringComparer.Ordinal)

let topicChoices (system: System) : TopicChoice array =
    choices.GetOrAdd(
        system.Variant.Key,
        fun _ ->
            system.Topics.List
            |> Array.map (fun (topic: Topics.Topic) ->
                let slug = topicSlug topic.Name

                { Name = topic.Name
                  Slug = slug
                  Key = topicSignalKey topic.Name
                  Description = topic.Description
                  Bind = "data-bind:topics." + slug }
            )
    )
