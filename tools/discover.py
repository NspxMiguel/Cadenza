#!/usr/bin/env python3
"""Crawl the classical v10 API by following action.url, and report what exists.

Navigation in this API is data: every item carries the path of the screen it
leads to. So the route table can be discovered rather than guessed. Reads
credentials from capture/tokens.json (gitignored).

    python3 tools/discover.py [max_requests]
"""
import json, os, sys, time, urllib.request, urllib.error
from collections import Counter, deque

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
BASE = "https://classical.music.apple.com/api/classical/v10"

with open(os.path.join(ROOT, "capture", "tokens.json")) as f:
    tok = json.load(f)
SF = tok.get("storefront", "us")
HEADERS = {
    "Authorization": "Bearer " + tok["developerToken"],
    "Music-User-Token": tok.get("musicUserToken", ""),
    "Origin": "https://classical.music.apple.com",
    "Referer": "https://classical.music.apple.com/",
}


def get(path):
    url = path if path.startswith("http") else BASE + path
    req = urllib.request.Request(url, headers=HEADERS)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.loads(r.read()), r.status
    except urllib.error.HTTPError as e:
        return None, e.code
    except Exception:
        return None, 0


def walk(node, hit):
    """Yield every action.url and record the type keys we encounter."""
    if isinstance(node, dict):
        act = node.get("action")
        if isinstance(act, dict) and isinstance(act.get("url"), str):
            hit(act["url"], act.get("screenType"))
        for key in ("type", "screenType", "itemType"):
            if isinstance(node.get(key), str):
                KINDS[key][node[key]] += 1
        for v in node.values():
            walk(v, hit)
    elif isinstance(node, list):
        for v in node:
            walk(v, hit)


KINDS = {"type": Counter(), "screenType": Counter(), "itemType": Counter()}
budget = int(sys.argv[1]) if len(sys.argv) > 1 else 40

seen, routes, queue = set(), {}, deque([
    f"/query/view/{SF}/listen-now",
    f"/query/view/{SF}//recently-added",
])
requests_made = 0

while queue and requests_made < budget:
    path = queue.popleft()
    shape = path.split("?")[0]
    if shape in seen:
        continue
    seen.add(shape)

    data, status = get(path)
    requests_made += 1
    routes[shape] = status
    print(f"{status}  {shape}")
    if not data:
        continue

    found = []
    walk(data, lambda u, st: found.append((u, st)))
    for u, st in found:
        if u.split("?")[0] not in seen:
            queue.append(u)
    time.sleep(0.25)  # be gentle; this is someone else's server

print(f"\n=== {requests_made} requisições, {len(routes)} rotas ===")
ok = [p for p, s in routes.items() if s == 200]
print(f"200: {len(ok)}   outros: {sorted(set(s for s in routes.values() if s != 200))}")

print("\n=== formas de rota ===")
import re
for s, n in Counter(re.sub(r"/\d{5,}", "/{id}", p) for p in ok).most_common(30):
    print(f"  {n:3}  {s}")

for key in ("screenType", "itemType", "type"):
    print(f"\n=== {key} ===")
    for k, n in KINDS[key].most_common(22):
        print(f"  {n:5}  {k}")
