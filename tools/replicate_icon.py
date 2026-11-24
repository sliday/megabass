"""Generate icon candidates on Replicate. usage: uv run replicate_icon.py <model> <n> <outdir> < prompt.txt"""
import json, os, sys, time, urllib.error, urllib.request
model, n, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
tok = os.environ["REPLICATE_API_TOKEN"]
H = {"Authorization": f"Bearer {tok}", "Content-Type": "application/json", "User-Agent": "megabass-icon/1.0"}
body = {"input": {"prompt": sys.stdin.read().strip(), "background": "transparent", "output_format": "png",
                  "quality": "high", "number_of_images": n, "aspect_ratio": "1:1", "moderation": "low"}}
req = urllib.request.Request(f"https://api.replicate.com/v1/models/{model}/predictions", json.dumps(body).encode(), H)
try:
    p = json.load(urllib.request.urlopen(req, timeout=60))
except urllib.error.HTTPError as e:
    sys.exit(f"HTTP {e.code}: {e.read().decode()[:400]}")
t0 = time.time()
while p["status"] not in ("succeeded", "failed", "canceled") and time.time() - t0 < 360:
    time.sleep(3)
    p = json.load(urllib.request.urlopen(urllib.request.Request(p["urls"]["get"], headers=H), timeout=30))
print(f"{model}: {p['status']} in {time.time() - t0:.0f}s", p.get("error") or "")
outs = p.get("output") or []
outs = outs if isinstance(outs, list) else [outs]
os.makedirs(out, exist_ok=True)
for i, u in enumerate(outs):
    path = os.path.join(out, f"{model.split('/')[-1]}-{i}.png")
    with urllib.request.urlopen(urllib.request.Request(u, headers={"User-Agent": "megabass-icon/1.0"}), timeout=60) as r, open(path, "wb") as f:
        f.write(r.read())
    print("saved", path)
