// Static assets, embedded and streamed.
//
// Two things force the shape of this file.
//
// `#load` puts every asset in the binary at compile time, so there is no filesystem read on the
// request path and no deployment step that can leave a file behind -- the same choice the Go port
// makes with `go:embed` and `todomvc-odin-htmx` makes with `#load`.
//
// Streaming, because `http.respond_bytes` does not stream: it copies the body into the connection's
// egress buffer and stages a 500 if it does not fit. Every asset here except `juice.css` is larger
// than the buffer, and `bulma.min.css` is ten times it. So each one goes out through a `get_event`
// route -- `begin_fixed_stream` declares the length up front, then each `Send_Ready` writes as much
// as the buffer will currently admit and flushes, until the whole file has been handed over.
package web

import "core:strings"
import http "tina:src/extensions/http/server"

Asset :: struct {
	name:          string,
	content_type:  string,
	cache_control: string,
	bytes:         []u8,
	// Both forms, filled at boot by `compress_assets`. Compressing these per request would pay
	// quality-5 brotli for an answer that never changes -- 678 KB of Bulma, every page load.
	encoded:       Encoded,
}

// Litestar serves this directory with `Cache-Control: no-cache` -- revalidate, do not cache blindly
// -- and the port keeps that so a stylesheet edit shows up on reload during development.
STATIC_CACHE_CONTROL :: "no-cache"

CSS :: "text/css; charset=utf-8"
JS :: "text/javascript; charset=utf-8"
JSON_MAP :: "application/json; charset=utf-8"

STATIC_ASSETS := []Asset {
	{
		name = "app.css",
		content_type = CSS,
		cache_control = STATIC_CACHE_CONTROL,
		bytes = #load("../assets/static/app.css"),
	},
	{
		name = "app-pico.css",
		content_type = CSS,
		cache_control = STATIC_CACHE_CONTROL,
		bytes = #load("../assets/static/app-pico.css"),
	},
	{
		name = "app-bulma.css",
		content_type = CSS,
		cache_control = STATIC_CACHE_CONTROL,
		bytes = #load("../assets/static/app-bulma.css"),
	},
	{
		name = "pico.classless.min.css",
		content_type = CSS,
		cache_control = STATIC_CACHE_CONTROL,
		bytes = #load("../assets/static/pico.classless.min.css"),
	},
	{
		name = "bulma.min.css",
		content_type = CSS,
		cache_control = STATIC_CACHE_CONTROL,
		bytes = #load("../assets/static/bulma.min.css"),
	},
	{
		name = "juice.css",
		content_type = CSS,
		cache_control = STATIC_CACHE_CONTROL,
		bytes = #load("../assets/static/juice.css"),
	},
	{
		name = "datastar.js",
		content_type = JS,
		cache_control = STATIC_CACHE_CONTROL,
		bytes = #load("../assets/static/datastar.js"),
	},
	// Not optional: without the source map devtools 404s on every open.
	{
		name = "datastar.js.map",
		content_type = JSON_MAP,
		cache_control = STATIC_CACHE_CONTROL,
		bytes = #load("../assets/static/datastar.js.map"),
	},
}

MEDIA_ASSETS := []Asset {
	{
		name = "completed.jpeg",
		content_type = "image/jpeg",
		cache_control = "max-age=31536000, public",
		bytes = #load("../assets/media/completed.jpeg"),
	},
}

// Compress every asset once, during boot. ~700 ms for this set, and it is the one place this port
// can be outright faster than the others rather than merely equal: they compress on the way out.
compress_assets :: proc(allocator := context.allocator) -> (compressed_count: int, saved: int) {
	for group in ([2][]Asset{STATIC_ASSETS, MEDIA_ASSETS}) {
		for &asset in group {
			asset.encoded = encode_asset(asset.bytes, allocator)
			if len(asset.encoded.brotli) > 0 {
				compressed_count += 1
				saved += len(asset.bytes) - len(asset.encoded.brotli)
			}
		}
	}
	return compressed_count, saved
}

// Where a partially-sent asset keeps its place between `Send_Ready` events. One of these exists per
// connection slot, sized at boot -- `state_size` on the route registration below.
Asset_Stream :: struct {
	asset:  ^Asset,
	// The form actually being sent -- identity or brotli, chosen per request.
	body:   []u8,
	offset: int,
}


serve_static :: proc(
	event: http.Route_Event,
	request: ^http.Request,
	response: ^http.Response,
	route_context: http.Route_Context,
	state: rawptr,
) -> http.Route_Step {
	return stream_asset(event, request, response, state, STATIC_ASSETS)
}

serve_media :: proc(
	event: http.Route_Event,
	request: ^http.Request,
	response: ^http.Response,
	route_context: http.Route_Context,
	state: rawptr,
) -> http.Route_Step {
	return stream_asset(event, request, response, state, MEDIA_ASSETS)
}

@(private = "file")
stream_asset :: proc(
	event: http.Route_Event,
	request: ^http.Request,
	response: ^http.Response,
	state: rawptr,
	assets: []Asset,
) -> http.Route_Step {
	stream := cast(^Asset_Stream)state

	switch _ in event {
	case http.Request_Start:
		stream^ = Asset_Stream{}
		name := string(http.param(request, "name"))
		asset := find_asset(assets, name)
		if asset == nil {
			return http.respond_text(response, http.HTTP_STATUS_NOT_FOUND, "not found")
		}
		stream.asset = asset

		if http.header_set(response, "Cache-Control", asset.cache_control) != .Staged {
			return http.close()
		}
		// The chosen form and the DECLARED LENGTH have to be the same decision. Tina asserts that a
		// fixed-length body matches its Content-Length exactly -- `flush(final): fixed-length body
		// size must match declared Content-Length` -- and the panic kills the connection isolate, so
		// the symptom is a reset rather than a short response.
		stream.body = choose_encoding(response, request, asset.encoded)
		if http.begin_fixed_stream(response, http.HTTP_STATUS_OK, asset.content_type, u64(len(stream.body))) !=
		   .Begun {
			return http.close()
		}
		return pump_asset(response, stream)

	case http.Send_Ready:
		if stream.asset == nil do return http.close()
		return pump_asset(response, stream)

	case http.Body_Chunk, http.Application_Reply, http.Application_Notification, http.Peer_Closed, http.Server_Drain:
		return http.close()
	}
	return http.close()
}

// Write until the egress buffer stops admitting bytes, then flush. `write_bytes` returns how much it
// actually took, which is the whole backpressure protocol: a short write is not an error, it means
// the buffer is full and the rest belongs to the next `Send_Ready`.
pump_asset :: proc(response: ^http.Response, stream: ^Asset_Stream) -> http.Route_Step {
	remaining := stream.body[stream.offset:]
	for len(remaining) > 0 {
		written := int(http.write_bytes(response, remaining))
		if written == 0 do break
		stream.offset += written
		remaining = remaining[written:]
	}
	return http.flush(final = len(remaining) == 0)
}

@(private = "file")
find_asset :: proc(assets: []Asset, name: string) -> ^Asset {
	for &asset in assets {
		if asset.name == name do return &asset
	}
	return nil
}

_ :: strings
