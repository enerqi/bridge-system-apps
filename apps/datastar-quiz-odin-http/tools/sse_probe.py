"""Timestamp every SSE frame of one answer, against a running dsquiz server.

    uv run --with httpx python sse_probe.py [base] [index]
"""

from __future__ import annotations

import re
import sys
import time

import httpx

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:5062"
PICK = int(sys.argv[2]) if len(sys.argv) > 2 else 0
DS = {"Datastar-Request": "true", "Content-Type": "application/json"}
SIGNALS = '{"difficulty":3,"ladderMode":false,"targetOn":false,"targetPct":80,"filterText":"","topics":{}}'


def main() -> None:
    with httpx.Client(base_url=BASE, timeout=30.0) as client:
        page = client.get("/").text
        answers = sorted(set(re.findall(r"/answer/(\d+)/(\d+)", page)))
        if not answers:
            raise SystemExit("no /answer/ links on the page")
        qid = answers[0][0]
        index = answers[min(PICK, len(answers) - 1)][1]
        print(f"qid {qid}, {len(answers)} candidates, picking index {index}")

        started = time.perf_counter()
        events: list[tuple[float, str]] = []
        with client.stream("POST", f"/answer/{qid}/{index}", headers=DS, content=SIGNALS) as response:
            print(f"status {response.status_code}  {dict(response.headers)}")
            buffer = ""
            for chunk in response.iter_raw():
                at = (time.perf_counter() - started) * 1000
                buffer += chunk.decode("utf-8", "replace")
                while "\n\n" in buffer:
                    frame, buffer = buffer.split("\n\n", 1)
                    first = frame.strip().splitlines()
                    head = first[0] if first else ""
                    body = " | ".join(line[:60] for line in first[1:3])
                    events.append((at, f"{head:<38} {body}"))

        previous = 0.0
        for at, text in events:
            print(f"  +{at - previous:7.1f} ms   {text}")
            previous = at
        print(f"total {previous:.0f} ms over {len(events)} events")


if __name__ == "__main__":
    main()
