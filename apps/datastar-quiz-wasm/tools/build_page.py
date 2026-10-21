# /// script
# requires-python = ">=3.12"
# dependencies = ["pillow"]
# ///
"""Assemble the quiz into ONE self-contained HTML file.

Usage: uv run --script tools/build_page.py <quiz.wasm> <out.html> <odin.js> [corpus.json ...]

With corpus files (exporter JSON, one per quiz system) the page is complete. Without them it is the
TEMPLATE: the same page with an empty slot where the corpus goes, for a program to fill. The contract
a filler relies on, and nothing else:

    the file contains `/*QUIZ_CORPUS*/` exactly once. Replace it with a JSON ARRAY of systems in the
    exporter's shape, with every `</` written as `<\\/` so the JSON cannot close its <script> element.

The notes workbench fills it from the `.bml` file it has open.

Everything the page needs goes inside it: the wasm module (gzipped, base64), Odin's JS runtime, the
host script, Datastar, the stylesheets and the finale picture. That is what lets the file be emailed,
copied to a USB stick or opened straight from disk -- a `file://` page may not fetch even a file
sitting next to it, so nothing can be left outside.

The assets are the tina port's own (`../datastar-quiz-tina/assets`), as its packages are.
"""

import base64
import gzip
import io
import json
import re
import sys
from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent.parent
TINA_ASSETS = HERE.parent / "datastar-quiz-tina" / "assets"

TITLE = "Bridge bidding quiz"
CORPUS_SLOT = "/*QUIZ_CORPUS*/"


def script_safe(text: str) -> str:
    """Text that cannot end the <script> element it is inlined into."""
    return re.sub(r"</(script)", r"<\\/\1", text, flags=re.IGNORECASE)


def without_imports(css: str) -> str:
    return re.sub(r'@import\s+url\([^)]*\);?', "", css)


def finale_picture(path: Path) -> bytes:
    """The finale's photo at the size it is shown (`width="600"`), not the 900KB original.

    Inlined as base64 it was two thirds of the page; nothing else in the file comes close.
    """
    image = Image.open(path).convert("RGB")
    image.thumbnail((1200, 1200))  # 2x the shown width, for a high-density screen
    out = io.BytesIO()
    image.save(out, "JPEG", quality=78, optimize=True, progressive=True)
    return out.getvalue()


def main() -> int:
    if len(sys.argv) < 4:
        print(__doc__, file=sys.stderr)
        return 2
    wasm_path, out_path, odin_js_path = (Path(arg) for arg in sys.argv[1:4])
    corpus_files = [Path(arg) for arg in sys.argv[4:]]
    if corpus_files:
        systems = [json.loads(path.read_text(encoding="utf-8")) for path in corpus_files]
        corpus = script_safe(json.dumps(systems, ensure_ascii=False, separators=(",", ":"))).replace("</", r"<\/")
    else:
        corpus = CORPUS_SLOT
    static = TINA_ASSETS / "static"

    # Pico's sheet pulls in the framework with a RELATIVE @import, which a blob URL cannot resolve.
    # Concatenated in order instead: the framework, then the app's rules over it.
    pico = (static / "pico.classless.min.css").read_text(encoding="utf-8")
    app_pico = without_imports((static / "app-pico.css").read_text(encoding="utf-8"))
    assets = {
        "css": {
            "app-pico.css": pico + "\n" + app_pico,
            "app.css": (static / "app.css").read_text(encoding="utf-8"),
            "juice.css": (static / "juice.css").read_text(encoding="utf-8"),
        },
        "media": {
            "completed.jpeg": base64.b64encode(finale_picture(TINA_ASSETS / "media" / "completed.jpeg")).decode(),
        },
        # The source-map comment would only produce a failed fetch in the devtools.
        "datastar": re.sub(r"//# sourceMappingURL=\S+\s*$", "", (static / "datastar.js").read_text(encoding="utf-8")),
    }

    wasm = gzip.compress(wasm_path.read_bytes(), compresslevel=9, mtime=0)
    odin_js = odin_js_path.read_text(encoding="utf-8")
    host_js = (HERE / "host" / "host.js").read_text(encoding="utf-8")

    page = f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8" /><meta name="viewport" content="width=device-width, initial-scale=1" />
<title>{TITLE}</title></head>
<body><p id="boot" style="font-family: system-ui, sans-serif; padding: 2rem">Loading the quiz…</p>
<noscript>This quiz runs in the page and needs JavaScript.</noscript>
<script id="quiz-corpus" type="application/json">{corpus}</script>
<script id="quiz-assets" type="application/json">{script_safe(json.dumps(assets, ensure_ascii=False))}</script>
<script>const QUIZ_WASM = "{base64.b64encode(wasm).decode()}";</script>
<script>{script_safe(odin_js)}</script>
<script>{script_safe(host_js)}</script>
</body></html>
"""
    out = Path(out_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(page, encoding="utf-8", newline="\n")
    kind = f"{len(corpus_files)} systems" if corpus_files else "TEMPLATE, corpus slot empty"
    print(f"{out}: {kind}, {len(page.encode()):,} bytes (wasm {wasm_path.stat().st_size:,} -> {len(wasm):,} gzipped)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
