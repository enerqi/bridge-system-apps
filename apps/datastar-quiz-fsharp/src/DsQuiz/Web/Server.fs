/// The route table and the middleware split.
///
/// TWENTY ROUTES, all under the optional mount prefix, and they fall into two groups that are handled
/// differently on purpose:
///
///  - THE DATASTAR ROUTES ARE STREAMS and compress themselves (see `Sse`). ASP.NET Core's
///    `ResponseCompression` does not touch `text/event-stream` -- it is absent from
///    `ResponseCompressionDefaults.MimeTypes` and the middleware supports no wildcards -- so there is
///    nothing to switch off, only something to remember.
///  - THE DOCUMENT AND THE ASSETS are whole responses. The page is compressed by hand here for the same
///    reason the streams are: the middleware's brotli provider exposes only `Level` (default `Fastest`,
///    which is quality 1) and has no minimum-size option at all, so it cannot express "quality 5, above
///    256 bytes" -- the ground rule every other port runs under. The assets were already compressed at
///    boot, which is better than either.
///
/// EVERY HANDLER IS BUILT ONCE, at startup, by partially applying `AppState`. In F# each partial
/// application is a closure allocation, so doing it per request would be one allocation per route per
/// request for values that never change.
module DsQuiz.Web.Server

open System
open System.Threading.Tasks
open Microsoft.AspNetCore.Http
open Oxpecker

open DsQuiz.Web

/// The endpoints, with every handler already bound to the application state.
///
/// The route placeholders are Oxpecker's `{%s}` / `{%i}` / `{%d}` form (ASP.NET route templates with an
/// F# format char), and the two asset routes are `{**%s}` catch-alls so `static/pico.classless.min.css`
/// arrives as one string rather than as three segments.
let endpoints (app: Handlers.AppState) : Oxpecker.RoutingTypes.Endpoint list =
    let prefix = app.Config.Prefix

    // Built once each: in F# a partial application is a closure allocation, so binding these per request
    // would be one allocation per route per request for values that never change.
    let index = Handlers.index app
    let answer = Handlers.answer app
    let next = Handlers.next app
    let skip = Handlers.skip app
    let restart = Handlers.restart app
    let settings = Handlers.settings app
    let timer = Handlers.timer app
    let filterPreview = Handlers.filterPreview app
    let topicsPreview = Handlers.topicsPreview app
    let topicsReset = Handlers.topicsReset app
    let filterApply = Handlers.filterApply app
    let topicsApply = Handlers.topicsApply app
    let debugPoints = Handlers.debugPoints app
    let debugGoal = Handlers.debugGoal app
    let debugComplete = Handlers.debugComplete app
    let debugReveal = Handlers.debugReveal app

    // NO `routef` ANYWHERE, and that is a Native AOT finding rather than a style choice.
    //
    // `routef` builds its ASP.NET route template by REFLECTING OVER THE HANDLER'S PARAMETERS
    // (`RouteTemplateBuilder.convertToRouteTemplate(string, ParameterInfo[])`). Under AOT that metadata
    // is trimmed, so the placeholder evaluator indexes past the end of the array and the app dies at
    // startup with an `IndexOutOfRangeException` before it serves a single request -- ILC compiles it
    // and the linker produces a working 16 MB exe, and then `routef` throws. Oxpecker's own README
    // offers `route` plus `TryGetRouteValue` for handlers with more than five parameters; here it is
    // what makes the third column exist at all. The cost is a dictionary lookup and a parse instead of
    // a reflection-built binding, which is if anything cheaper.
    let routeValue (name: string) (ctx: HttpContext) =
        match ctx.Request.RouteValues.TryGetValue name with
        | true, value when value <> null -> string value
        | _ -> ""

    /// A route with one integer segment: 404 rather than 500 when it is not a number, because the only
    /// way to reach one is a hand-typed URL.
    let withInt (name: string) (handler: int -> EndpointHandler) : EndpointHandler =
        fun ctx ->
            match Int32.TryParse(routeValue name ctx) with
            | true, value -> handler value ctx
            | _ ->
                ctx.Response.StatusCode <- StatusCodes.Status404NotFound
                Task.CompletedTask

    let answerRoute: EndpointHandler =
        fun ctx ->
            match Int64.TryParse(routeValue "qid" ctx), Int32.TryParse(routeValue "index" ctx) with
            | (true, qid), (true, index) -> answer qid index ctx
            | _ ->
                ctx.Response.StatusCode <- StatusCodes.Status404NotFound
                Task.CompletedTask

    let assetRoute
        (folder: Handlers.AppState -> string -> string -> EndpointHandler)
        (which: string)
        : EndpointHandler =
        fun ctx -> folder app which (routeValue "path" ctx) ctx

    let tree =
        [ GET
              [ route "/" index
                route "/timer" timer
                route "/filter/preview" filterPreview
                route "/filter/preview-topics" topicsPreview
                route "/filter/topics-reset" topicsReset
                route "/sfx/{name}" (fun ctx -> Handlers.sound (routeValue "name" ctx) ctx)
                route "/static/{**path}" (assetRoute Handlers.asset "static")
                route "/media/{**path}" (assetRoute Handlers.asset "media") ]
          POST
              [ route "/answer/{qid}/{index}" answerRoute
                route "/next" next
                route "/skip" skip
                route "/restart" restart
                route "/settings" settings
                route "/filter/apply" filterApply
                route "/filter/apply-topics" topicsApply
                // The debug panel: the panel app's row of buttons for reaching a state that takes minutes
                // of honest play. Every route is a no-op unless the session is armed, so an unarmed
                // instance answers with a 204 rather than a 404 -- the same "nothing to do" answer a
                // stale qid gets, and it does not advertise whether the routes exist.
                route "/debug/points/{delta}" (withInt "delta" debugPoints)
                route "/debug/goal/{value}" (withInt "value" debugGoal)
                route "/debug/complete" debugComplete
                route "/debug/reveal" debugReveal ] ]

    // THE MOUNT PREFIX IS A `subRoute`, which also keeps the route templates above literal.
    if prefix = "" then tree else [ subRoute prefix tree ]
