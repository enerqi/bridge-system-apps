"""Per-connection memory cost: open N keep-alive sockets, one request each, hold them, sample RSS."""
import socket, subprocess, sys, time

HOST, PORT = "127.0.0.1", 5062
PATH = sys.argv[1] if len(sys.argv) > 1 else "/health"
STEPS = [0, 100, 250, 500]

def rss_mb() -> float:
    out = subprocess.run(
        ["powershell", "-NoProfile", "-Command",
         "$p = Get-CimInstance Win32_Process -Filter \"name = 'main.exe'\" | "
         "Where-Object { $_.ExecutablePath -like '*odin-http*' }; "
         "(Get-Process -Id $p.ProcessId).WorkingSet64"],
        capture_output=True, text=True)
    return int(out.stdout.strip()) / 1024 / 1024

request = f"GET {PATH} HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept-Encoding: identity\r\n\r\n".encode()
socks = []
base = rss_mb()
print(f"{'conns':>6} {'RSS MB':>9} {'delta':>8} {'KB/conn':>9}   ({PATH})")
print(f"{0:>6} {base:>9.1f} {0.0:>8.1f} {'-':>9}")

for target in STEPS[1:]:
    while len(socks) < target:
        s = socket.create_connection((HOST, PORT))
        s.settimeout(5)
        s.sendall(request)
        try:
            s.recv(65536)
        except socket.timeout:
            pass
        socks.append(s)
    time.sleep(1.5)
    now = rss_mb()
    delta = now - base
    print(f"{len(socks):>6} {now:>9.1f} {delta:>8.1f} {delta * 1024 / len(socks):>9.1f}")
    sys.stdout.flush()

for s in socks:
    s.close()
time.sleep(2)
print(f"after close: {rss_mb():.1f} MB")
