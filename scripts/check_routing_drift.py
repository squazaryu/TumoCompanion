#!/usr/bin/env python3
"""Routing-drift check for CI (issue #11).

Downloads the latest all-the-plugins release, enumerates every .fap (stem + upstream
category), and compares against routing/module_one_routes.json to surface:

  * stale      — a mapped stem that no longer exists upstream (renamed/removed);
  * candidates — a NEW upstream app that lives in the same category as apps we already
                 route to Module One (so it may belong in Module One too).

"New" is measured against routing/upstream_snapshot.json so the report only shows genuine
additions, not the whole pack every run. Writes the refreshed snapshot and a markdown
report (routing-drift-report.md) for the tracking issue, and emits `drift=true|false`.
"""
import json
import os
import pathlib
import tempfile
import urllib.request
import zipfile

REPO = "xMasterX/all-the-plugins"
ASSETS = ["all-the-apps-base.zip", "all-the-apps-extra.zip"]
MARKERS = ("artifacts-base/", "artifacts-extra/")
ROUTES_F = pathlib.Path("routing/module_one_routes.json")
SNAP_F = pathlib.Path("routing/upstream_snapshot.json")
REPORT_F = pathlib.Path("routing-drift-report.md")


def _req(url: str, accept: str) -> urllib.request.Request:
    headers = {"Accept": accept, "User-Agent": "routing-drift-check"}
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = "Bearer " + token
    return urllib.request.Request(url, headers=headers)


def latest_release() -> dict:
    with urllib.request.urlopen(_req(
            f"https://api.github.com/repos/{REPO}/releases/latest",
            "application/vnd.github+json")) as r:
        return json.load(r)


def enumerate_stems(tmp: str, assets: dict) -> dict:
    """Return {stem: upstream_category} for every .fap across the release zips."""
    stems: dict[str, str] = {}
    for name in ASSETS:
        url = assets.get(name)
        if not url:
            continue
        path = os.path.join(tmp, name)
        # browser_download_url is public — no auth header (avoids the S3 redirect auth issue).
        with urllib.request.urlopen(_req(url, "application/octet-stream")) as resp, open(path, "wb") as f:
            f.write(resp.read())
        with zipfile.ZipFile(path) as zf:
            for entry in zf.namelist():
                if not entry.endswith(".fap"):
                    continue
                for marker in MARKERS:
                    i = entry.find(marker)
                    if i < 0:
                        continue
                    parts = entry[i + len(marker):].split("/")
                    if len(parts) >= 2:
                        stems[parts[-1][:-4]] = parts[-2]   # strip ".fap"; category = parent dir
                    break
    return stems


def main() -> int:
    routes = json.loads(ROUTES_F.read_text())["routes"]
    mapped = set(routes)

    rel = latest_release()
    tag = rel.get("tag_name", "unknown")
    assets = {a["name"]: a["browser_download_url"] for a in rel.get("assets", [])}

    with tempfile.TemporaryDirectory() as tmp:
        stems = enumerate_stems(tmp, assets)
    current = set(stems)
    if not current:
        print("error: no .fap entries enumerated — aborting without touching state", flush=True)
        return 1

    stale = sorted(mapped - current)

    # Upstream categories our mapped apps currently live in → the "Module One source set".
    mo_categories = {stems[s] for s in mapped if s in stems}

    first_run = not SNAP_F.exists()
    prev = set(json.loads(SNAP_F.read_text()).get("stems", {})) if not first_run else set()
    new_stems = current - prev
    candidates = sorted(
        s for s in new_stems if not first_run and stems[s] in mo_categories and s not in mapped
    )

    SNAP_F.parent.mkdir(parents=True, exist_ok=True)
    SNAP_F.write_text(json.dumps(
        {"release_tag": tag, "stems": dict(sorted(stems.items()))},
        indent=2, ensure_ascii=False) + "\n")

    drift = bool(stale or candidates)
    lines = [f"_Checked against all-the-plugins `{tag}` — {len(current)} apps, {len(mapped)} mapped._", ""]
    if stale:
        lines.append("### ⚠️ Stale routing entries (mapped stem no longer upstream)")
        lines += [f"- `{s}` → `{routes[s]}`" for s in stale] + [""]
    if candidates:
        lines.append("### 🆕 New apps in Module One categories — review whether they belong in the map")
        lines += [f"- `{s}`  ·  upstream category `{stems[s]}`" for s in candidates] + [""]
    if not drift:
        lines.append("First run — snapshot seeded; new-app detection starts next run."
                     if first_run else
                     "✅ No drift: every mapped app is present upstream and no new apps appeared "
                     "in Module One categories.")
    REPORT_F.write_text("\n".join(lines) + "\n")
    print("\n".join(lines))

    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a") as o:
            o.write(f"drift={'true' if drift else 'false'}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
