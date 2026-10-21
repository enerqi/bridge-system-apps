// The page's half of the quiz: start the wasm module, then stand in for the server.
//
// Everything the module needs arrives inlined in the one HTML file -- the gzipped wasm as base64, the
// stylesheets and the finale picture in a JSON block -- because the page has to work opened straight
// from disk, where a `file://` document may not fetch anything, not even a file next to it.
//
// The module renders the same markup the servers do, Datastar actions included. `window.fetch` is
// replaced so that a request to the module's mount point (`/__quiz/...`) never reaches the network:
// it is answered by `qz_request`, whose script comes back as a streamed `text/event-stream` body with
// its pauses waited out, which is all Datastar can see of a server anyway.
(async () => {
	"use strict";

	const PREFIX = "/__quiz";
	const encoder = new TextEncoder();
	const decoder = new TextDecoder();

	const bootMessage = (text) => {
		const element = document.getElementById("boot");
		if (element) element.textContent = text;
	};

	// -- the module --------------------------------------------------------------------------

	const gunzip = async (base64) => {
		const bytes = Uint8Array.from(atob(base64), (ch) => ch.charCodeAt(0));
		const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("gzip"));
		return new Response(stream).arrayBuffer();
	};

	const memory = new odin.WasmMemoryInterface();
	memory.setIntSize(4);
	const imports = odin.setupDefaultImports(memory, null, memory.memory);
	const { instance } = await WebAssembly.instantiate(await gunzip(QUIZ_WASM), imports);
	const wasm = instance.exports;
	memory.setExports(wasm);
	memory.setMemory(wasm.memory);
	wasm._start();

	const bytesAt = (pointer, length) => new Uint8Array(wasm.memory.buffer, pointer, length);
	const put = (text) => {
		const bytes = encoder.encode(text);
		const pointer = wasm.qz_alloc(bytes.length);
		bytesAt(pointer, bytes.length).set(bytes);
		return [pointer, bytes.length];
	};

	// The corpus travels beside the module, not inside it -- see `src/main.odin`. Parsed and indexed
	// here, once.
	const systems = JSON.parse(document.getElementById("quiz-corpus").textContent);
	if (!Array.isArray(systems) || systems.length === 0) throw new Error("this page carries no quiz corpus");
	// A system can carry its NOTES as a whole html document (a quiz the notes workbench generated has no
	// published page to embed). Lifted out here - the engine has no use for it - and given to the "System
	// Notes" panel as a local copy below; `system_notes_url` names that copy (`/__quiz/notes/<i>`).
	const notesPages = systems.map((system) => system.system_notes_html || "");
	for (const system of systems) {
		const { system_notes_html: _, ...forEngine } = system;
		wasm.qz_add_system(...put(JSON.stringify(forEngine)));
	}
	if (!wasm.qz_start()) throw new Error("the quiz corpus did not load");

	// One request, start to finish, synchronously. The request is
	// `METHOD\nPATH\nQUERY\nCOOKIE\nBODY`; see `src/main.odin`.
	const ask = (method, path, query, body) => {
		let cookie = "";
		try {
			cookie = document.cookie;
		} catch {
			// an opaque origin can refuse cookies outright
		}
		const length = wasm.qz_request(...put([method, path, query, cookie, body].join("\n")));
		return decoder.decode(bytesAt(wasm.qz_result(), length).slice());
	};

	// -- the assets ----------------------------------------------------------------------------

	const ASSETS = JSON.parse(document.getElementById("quiz-assets").textContent);
	const assetUrls = new Map();
	const blobUrl = (bytes, type) => URL.createObjectURL(new Blob([bytes], { type }));

	for (const [name, text] of Object.entries(ASSETS.css)) {
		assetUrls.set(`${PREFIX}/static/${name}`, blobUrl(text, "text/css"));
	}
	for (const [name, base64] of Object.entries(ASSETS.media)) {
		const bytes = Uint8Array.from(atob(base64), (ch) => ch.charCodeAt(0));
		assetUrls.set(`${PREFIX}/media/${name}`, blobUrl(bytes, "image/jpeg"));
	}
	assetUrls.set(`${PREFIX}/static/datastar.js`, blobUrl(ASSETS.datastar, "text/javascript"));
	notesPages.forEach((html, index) => {
		if (html) assetUrls.set(`${PREFIX}/notes/${index}`, blobUrl(html, "text/html"));
	});

	// The sounds are synthesised by the module at boot, as the servers do, rather than shipped.
	const sizeCell = wasm.qz_alloc(4);
	for (let index = 0; index < wasm.qz_sound_count(); index++) {
		const namePointer = wasm.qz_sound_name(index, sizeCell);
		const name = decoder.decode(bytesAt(namePointer, new Int32Array(wasm.memory.buffer, sizeCell, 1)[0]).slice());
		const wavPointer = wasm.qz_sound_bytes(index, sizeCell);
		const wav = bytesAt(wavPointer, new Int32Array(wasm.memory.buffer, sizeCell, 1)[0]).slice();
		assetUrls.set(`${PREFIX}/sfx/${name}?v=wasm`, blobUrl(wav, "audio/wav"));
	}

	// Asset URLs are rewritten in the TEXT -- the page, and every patch streamed into it, since the
	// finale's picture arrives in one -- never on the live DOM. A MutationObserver on `href`/`src` was
	// tried first and hung the tab: Datastar re-applies `data-attr:href` when the attribute changes, the
	// observer changed it back, and the two took turns forever.
	//
	// The one URL a literal rewrite cannot reach is the stylesheet picker's, which Datastar BUILDS
	// (`'/__quiz/static/app-' + $_css + '.css'`). The picker is a debug-only affordance, so this page
	// drops the binding and keeps the default sheet.
	const rewrite = (html) => {
		html = html.replace(/(<link rel="stylesheet") data-attr:href="[^"]*"/, "$1");
		for (const [from, to] of assetUrls) html = html.split(from).join(to);
		return html;
	};

	// -- the server, in the page --------------------------------------------------------------

	const sleep = (ms, signal) =>
		new Promise((resolve) => {
			const timer = setTimeout(resolve, ms);
			signal?.addEventListener("abort", () => {
				clearTimeout(timer);
				resolve();
			});
		});

	// An SSE body that plays the script out: events between NULs are sent at once, the field after
	// each NUL is a pause in milliseconds.
	const streamScript = (sse, signal) => {
		const fields = sse.split("\0");
		return new ReadableStream({
			async start(controller) {
				for (let index = 0; index < fields.length; index++) {
					if (signal?.aborted) break;
					if (index % 2 === 1) {
						await sleep(Number(fields[index]), signal);
					} else if (fields[index] !== "") {
						controller.enqueue(encoder.encode(fields[index]));
					}
				}
				controller.close();
			},
		});
	};

	const networkFetch = window.fetch.bind(window);
	window.fetch = async (input, init = {}) => {
		const url = new URL(typeof input === "string" ? input : input.url, location.href);
		const at = url.pathname.indexOf(`${PREFIX}/`);
		if (at < 0) return networkFetch(input, init);

		const method = (init.method || "GET").toUpperCase();
		const body = typeof init.body === "string" ? init.body : "";
		const answer = ask(method, url.pathname.slice(at + PREFIX.length), url.search.slice(1), body);

		switch (answer[0]) {
			case "S":
				return new Response(streamScript(rewrite(answer.slice(1)), init.signal), {
					status: 200,
					headers: { "Content-Type": "text/event-stream" },
				});
			case "D":
				return new Response(answer.slice(1), { status: 200, headers: { "Content-Type": "text/html" } });
			default:
				return new Response(null, { status: 204 });
		}
	};

	// -- the page ------------------------------------------------------------------------------

	bootMessage("Rendering…");
	const page = ask("GET", "/", location.search.slice(1), "");
	if (page[0] !== "D") {
		bootMessage("The quiz could not start: the module rendered no page.");
		return;
	}
	// `document.open` keeps this window -- and so the `fetch` above -- and replaces only the document.
	document.open();
	document.write(rewrite(page.slice(1)));
	document.close();
})().catch((error) => {
	console.error(error);
	const element = document.getElementById("boot");
	if (element) element.textContent = `The quiz could not start: ${error}`;
});
