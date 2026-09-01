/// Every setting a run used, in one record, logged at startup.
///
/// The rule this port inherits from the Go one: anything that could tilt the comparison is a flag
/// with a default that says so, and a startup log line is enough to reconstruct a run.
///
/// ONE KNOB IS NOT HERE, and cannot be. The other ports take their core budget as an argument
/// (`--procs 1`, `--threads 1`, one shard); .NET reads its processor count during runtime
/// initialisation, before any of our code runs, so the like-for-like budget is the ENVIRONMENT
/// variable `DOTNET_PROCESSOR_COUNT=1` set by the `serve-1core` recipe. It lands on
/// `Environment.ProcessorCount`, Kestrel's IO queue count and the server GC's heap count at once,
/// which is why it is the honest single knob. What we can do here is REPORT it, so a log line still
/// says which budget a run had.
module DsQuiz.Web.Config

open System

/// `DSQUIZ_TIMER`: who pushes the countdown.
type TimerMode =
    /// the browser ticks it locally with `data-on-interval`
    | ClientTimer
    /// the server holds a connection open and pushes `_timeLeftPct` every 100ms
    | StreamTimer

/// `DSQUIZ_MORPH`: how much DOM one interaction carries.
type MorphMode =
    /// patch the whole `#app`
    | FatMorph
    /// patch `#quiz` only
    | FragmentMorph

/// `DSQUIZ_DEBUG`: whether the debug panel is reachable.
type DebugMode =
    /// per-session, armed by visiting `?debug`
    | DebugPerSession
    /// always armed
    | DebugAlways
    /// never armed, `?debug` ignored
    | DebugNever

type Config =
    {
        Addr: string
        Port: int
        Timer: TimerMode
        Morph: MorphMode
        /// one leading slash, no trailing one; empty for a root mount
        Prefix: string
        Debug: DebugMode
    }

    member this.StreamTimer = this.Timer = StreamTimer
    member this.FatMorph = this.Morph = FatMorph

/// The text forms of the three modes.
///
/// These exist because `%A` DOES NOT SURVIVE NATIVE AOT: F#'s printf implementation reflects over the
/// format specifiers (`MethodInfo.MakeGenericMethod`), which AOT cannot do, and the startup line is the
/// one place this app formats anything. Spelling the cases out is both AOT-safe and better output.
let timerText (mode: TimerMode) : string =
    match mode with
    | ClientTimer -> "client"
    | StreamTimer -> "stream"

let morphText (mode: MorphMode) : string =
    match mode with
    | FatMorph -> "fat"
    | FragmentMorph -> "fragment"

let debugText (mode: DebugMode) : string =
    match mode with
    | DebugPerSession -> "per-session"
    | DebugAlways -> "always"
    | DebugNever -> "never"

let private envOr (name: string) (fallback: string) : string =
    match Environment.GetEnvironmentVariable name with
    | null -> fallback
    | "" -> fallback
    | value -> value

let private envInt (name: string) (fallback: int) : int =
    match Int32.TryParse(envOr name "") with
    | true, parsed -> parsed
    | _ -> fallback

/// `bridge-quiz-ds`, `/bridge-quiz-ds` and `/bridge-quiz-ds/` all mean `/bridge-quiz-ds`; unset
/// means the root. Mirrors the python, and `normalisePrefix` in the Go port's `cmd/quizd/main.go`.
let normalisePrefix (prefix: string) : string =
    let trimmed = prefix.Trim('/')
    if trimmed = "" then "" else "/" + trimmed

let private timerOf value : TimerMode =
    if String.Equals(value, "stream", StringComparison.OrdinalIgnoreCase) then
        StreamTimer
    else
        ClientTimer

let private morphOf value : MorphMode =
    if String.Equals(value, "fragment", StringComparison.OrdinalIgnoreCase) then
        FragmentMorph
    else
        FatMorph

let private debugOf value : DebugMode =
    match value with
    | "1" -> DebugAlways
    | "0" -> DebugNever
    | _ -> DebugPerSession

/// Flags win over the environment, which wins over the default -- the same precedence the Go port's
/// `flag.String(name, envOr(...), ...)` gives, spelled out because F# has no flag package.
let parse (argv: string array) : Config =
    let flags = Collections.Generic.Dictionary<string, string>(StringComparer.Ordinal)

    let rec collect (index: int) : unit =
        if
            index < argv.Length - 1
            && argv[index].StartsWith("--", StringComparison.Ordinal)
        then
            flags[argv[index].Substring 2] <- argv[index + 1]
            collect (index + 2)
        elif index < argv.Length then
            // a stray argument: ignore it rather than fail a load run over a typo
            collect (index + 1)

    collect 0

    let flag (name: string) (fallback: string) : string =
        match flags.TryGetValue name with
        | true, value -> value
        | _ -> fallback

    { Addr = flag "addr" (envOr "DSQUIZ_ADDR" "127.0.0.1")
      Port =
        match Int32.TryParse(flag "port" "") with
        | true, parsed -> parsed
        | _ -> envInt "DSQUIZ_PORT" 5080
      Timer = timerOf (flag "timer" (envOr "DSQUIZ_TIMER" "client"))
      Morph = morphOf (flag "morph" (envOr "DSQUIZ_MORPH" "fat"))
      Prefix = normalisePrefix (flag "prefix" (envOr "DSQUIZ_PREFIX" ""))
      Debug = debugOf (flag "debug" (envOr "DSQUIZ_DEBUG" "")) }
