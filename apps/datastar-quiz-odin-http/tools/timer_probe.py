import sys, time, httpx
BASE = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:5062"
with httpx.Client(base_url=BASE, timeout=30.0) as c:
    c.get("/")
    started = time.perf_counter()
    times = []
    with c.stream("GET", "/timer", headers={"Datastar-Request": "true"}) as r:
        print("status", r.status_code, dict(r.headers))
        for chunk in r.iter_raw():
            times.append((time.perf_counter() - started) * 1000)
            if len(times) >= 21:
                break
gaps = [round(b - a, 1) for a, b in zip(times, times[1:])]
print("first at", round(times[0], 1), "ms")
print("gaps:", gaps)
print("mean gap", round(sum(gaps) / len(gaps), 1), "ms over", len(gaps))
