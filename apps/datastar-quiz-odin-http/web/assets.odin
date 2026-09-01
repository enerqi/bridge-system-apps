// Static assets, embedded.
//
// `#load` puts every asset in the binary at compile time, so there is no filesystem read on the
// request path and no deployment step that can leave a file behind -- the same choice the Go port
// makes with `go:embed`, and the same one the sibling Tina port makes.
//
// Unlike that port, nothing here streams. Tina stages a response in a fixed per-connection egress
// buffer and refuses a body larger than it, so every asset except `juice.css` had to go out through
// an event route that wrote and flushed until the file was gone -- 678 KB of Bulma against a 63 KB
// buffer. odin-http builds a response body in a growing arena and sends it with one `nbio.send`, so
// an asset is `body_set` and `respond`. Whether that is a better trade is a memory question, and it
// is in RESULTS.md.
package web

import http "odinhttp:."

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

// Point every asset's identity form at its embedded bytes.
//
// Unconditional, and separate from `compress_assets` for exactly that reason: the brotli half is
// behind `-define:DSQUIZ_BROTLI=true`, and an `Encoded` whose identity was only ever filled in on
// the compressing path serves every stylesheet as `content-length: 0` in the default build -- a 200
// with the right content type and no bytes, which no browser and no test reports as a failure.
init_assets :: proc() {
	for group in ([2][]Asset{STATIC_ASSETS, MEDIA_ASSETS}) {
		for &asset in group {
			asset.encoded.identity = asset.bytes
		}
	}
}

// Compress every asset once, during boot. ~700 ms for this set, and it is the one place the two Odin
// ports agree against the other three: they compress on the way out, these are already done.
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

route_static :: proc(request: ^http.Request, response: ^http.Response) {
	serve_asset(request, response, STATIC_ASSETS)
}

route_media :: proc(request: ^http.Request, response: ^http.Response) {
	serve_asset(request, response, MEDIA_ASSETS)
}

@(private = "file")
serve_asset :: proc(request: ^http.Request, response: ^http.Response, assets: []Asset) {
	name := len(request.url_params) > 0 ? request.url_params[0] : ""
	asset := find_asset(assets, name)
	if asset == nil {
		http.respond_plain(response, "not found", .Not_Found)
		return
	}
	respond_prepared(request, response, asset.encoded, asset.content_type, asset.cache_control)
}

@(private = "file")
find_asset :: proc(assets: []Asset, name: string) -> ^Asset {
	for &asset in assets {
		if asset.name == name {
			return &asset
		}
	}
	return nil
}
