// The module's routes, driven headless: node tools/smoke.mjs <quiz.wasm> <odin.js> <system.json>...
//
// No browser and no Datastar -- this asks `qz_request` the same questions `host.js` does and checks
// the shape of what comes back. The packages under it have their own tests in the tina port (the
// filter goldens among them); what this covers is THIS app's half: routing, the request encoding, the
// script and its wire format, and that the module boots at all on js_wasm32.
import assert from "node:assert/strict";
import fs from "node:fs";

const [wasmPath, odinJsPath, ...systemPaths] = process.argv.slice(2);
if (!wasmPath || !odinJsPath || systemPaths.length === 0) {
	console.error("usage: node tools/smoke.mjs <quiz.wasm> <odin.js> <system.json>...");
	process.exit(2);
}

// odin.js is written for a browser window and installs itself as `window.odin`.
globalThis.window = globalThis;
globalThis.document = { getElementById: () => null };
(0, eval)(fs.readFileSync(odinJsPath, "utf8"));

const memory = new odin.WasmMemoryInterface();
memory.setIntSize(4);
const imports = odin.setupDefaultImports(memory, null, memory.memory);
const { instance } = await WebAssembly.instantiate(fs.readFileSync(wasmPath), imports);
const wasm = instance.exports;
memory.setExports(wasm);
memory.setMemory(wasm.memory);
wasm._start();

// The corpus is handed over at runtime, as `host.js` does from the page.
const put = (text) => {
	const bytes = new TextEncoder().encode(text);
	const pointer = wasm.qz_alloc(bytes.length);
	new Uint8Array(wasm.memory.buffer, pointer, bytes.length).set(bytes);
	return [pointer, bytes.length];
};
for (const path of systemPaths) wasm.qz_add_system(...put(fs.readFileSync(path, "utf8")));
assert.equal(wasm.qz_start(), 1, "the corpus did not load");

const ask = (method, path, query = "", body = "") => {
	const request = new TextEncoder().encode([method, path, query, "", body].join("\n"));
	const pointer = wasm.qz_alloc(request.length);
	new Uint8Array(wasm.memory.buffer, pointer, request.length).set(request);
	const length = wasm.qz_request(pointer, request.length);
	return new TextDecoder().decode(new Uint8Array(wasm.memory.buffer, wasm.qz_result(), length).slice());
};

let failures = 0;
const check = (name, test) => {
	try {
		test();
		console.log(`ok    ${name}`);
	} catch (error) {
		failures++;
		console.log(`FAIL  ${name}\n      ${error.message.split("\n").join("\n      ")}`);
	}
};

const liveQid = (html) => Number(html.match(/\/answer\/(\d+)\//)[1]);

check("the index page is a whole document, on the default variant", () => {
	const page = ask("GET", "/");
	assert.equal(page[0], "D");
	assert.match(page, /^D<!DOCTYPE html>/);
	assert.match(page, /<title>U16 Squad System Quiz<\/title>/);
	assert.match(page, /class="candidates"/);
});

check("?swedish switches the variant, and the action urls carry it", () => {
	const page = ask("GET", "/", "swedish");
	assert.match(page, /<title>Swedish Club Quiz<\/title>/);
	assert.match(page, /\/__quiz\/answer\/\d+\/0\?swedish/);
});

check("an answer is an SSE script: streak first, a paced toast, the fat morph last", () => {
	const page = ask("GET", "/", "squad");
	const script = ask("POST", `/answer/${liveQid(page)}/0`, "squad", "{}");
	assert.equal(script[0], "S");
	const events = script.slice(1).split("\0").filter((_, index) => index % 2 === 0).join("");
	assert.match(events, /^event: datastar-patch-signals\ndata: signals \{"_streak":\d+\}\n\n/);
	assert.match(events, /data: selector #app\ndata: mode inner\ndata: elements /);
	assert.match(events, /event: datastar-patch-signals\ndata: signals [^\n]*\n\n$/);
	const pauses = script.split("\0").filter((_, index) => index % 2 === 1).map(Number);
	assert.ok(pauses.length > 0 && pauses.every((ms) => ms > 0), `pauses: ${pauses}`);
});

check("a stale question id resyncs instead of scoring", () => {
	const script = ask("POST", "/answer/999999/0", "squad", "{}");
	assert.equal(script[0], "S");
	assert.match(script, /this page has caught up/);
});

check("Next off a reveal is a no-op (the server's 204)", () => {
	ask("POST", "/restart", "squad", "{}");
	assert.equal(ask("POST", "/next", "squad", "{}"), "N");
});

check("a filter preview reports without adopting; apply restarts on the canonical text", () => {
	const preview = ask("GET", "/filter/preview", `squad&datastar=${encodeURIComponent('{"filterText":"1c"}')}`);
	assert.match(preview, /auctions? match/);
	assert.match(preview, /press Enter to apply/);
	const applied = ask("POST", "/filter/apply", "squad", '{"filterText":"1c"}');
	assert.match(applied, /"filterText":"1C"/);
	assert.match(applied, /data: selector #app/);
	assert.equal(ask("POST", "/filter/apply", "squad", '{"filterText":"1C"}').includes("selector #app"), false);
});

check("restart applies a filter that was typed but not applied with Enter", () => {
	ask("POST", "/filter/apply", "squad", '{"filterText":""}');
	ask("GET", "/filter/preview", `squad&datastar=${encodeURIComponent('{"filterText":"1N"}')}`);
	const restarted = ask("POST", "/restart", "squad", '{"filterText":"1N"}');
	assert.match(restarted, /"filterText":"1N"/);
	assert.match(restarted, /data: selector #app/);
	// and a restart with nothing pending is a plain restart on the filter in force
	const again = ask("POST", "/restart", "squad", '{"filterText":"1N"}');
	assert.match(again, /data: selector #app/);
	assert.doesNotMatch(again, /selector #filter-status/);
});

check("a settings post that changes nothing is a no-op; one that does restarts", () => {
	ask("POST", "/settings", "squad", '{"difficulty":5}');
	assert.equal(ask("POST", "/settings", "squad", '{"difficulty":5}'), "N");
	assert.match(ask("POST", "/settings", "squad", '{"difficulty":6}'), /selector #app/);
});

check("malformed signals read as none uploaded, not as an error", () => {
	assert.equal(ask("POST", "/settings", "squad", "{not json"), "N");
});

check("the topic picker offers only topics with enough auctions to quiz on", () => {
	const page = ask("GET", "/", "squad");
	const squad = JSON.parse(fs.readFileSync(systemPaths[0], "utf8"));
	const offered = squad.topics.filter((topic) => page.includes(`>${topic.name}<`) || page.includes(`${topic.name}</`));
	assert.ok(offered.length > 0, "some squad topics should be offered");
	assert.ok(offered.length <= squad.topics.length);
});

check("the sounds are synthesised at boot", () => {
	assert.equal(wasm.qz_sound_count(), 5);
});

check("debug routes do nothing unless the page was opened with ?debug", () => {
	assert.equal(ask("POST", "/debug/complete", "squad", "{}"), "N");
	ask("GET", "/", "squad&debug");
	assert.match(ask("POST", "/debug/complete", "squad", "{}"), /finished/);
});

console.log(failures === 0 ? "\nall passed" : `\n${failures} failed`);
process.exit(failures === 0 ? 0 : 1);
