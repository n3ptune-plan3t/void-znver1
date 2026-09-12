#!/usr/bin/env python3
"""
Reads packages.txt / large-packages.txt, fetches each package's current
`version=` / `revision=` from the void-packages template via the GitHub
Contents API, and diffs it against state/built.json.

Writes two JSON matrices (normal / large) to $GITHUB_OUTPUT so a workflow
can fan them out with `strategy: matrix: fromJson(...)`, and sets
`has_updates` / `has_large_updates` booleans.

Doesn't need a PAT for public-repo reads, but uses GITHUB_TOKEN if present
to get the 5000/hr authenticated rate limit instead of 60/hr anonymous.
"""
import base64
import json
import os
import re
import sys
import urllib.request
import urllib.error

VOID_REPO = "void-linux/void-packages"
API_ROOT = f"https://api.github.com/repos/{VOID_REPO}/contents/srcpkgs"
STATE_PATH = "state/built.json"
VERSION_RE = re.compile(r'^\s*version=(\S+)', re.M)
REVISION_RE = re.compile(r'^\s*revision=(\S+)', re.M)


def gh_get(url):
    req = urllib.request.Request(url)
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Accept", "application/vnd.github+json")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        print(f"  ! GitHub API error for {url}: {e.code} {e.reason}", file=sys.stderr)
        return None


def read_pkg_list(path):
    if not os.path.exists(path):
        return []
    out = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            out.append(line)
    return out


def resolve_template(pkgname):
    """
    srcpkgs/<pkg> in void-packages is either a directory containing
    `template`, or a symlink (subpackage alias) pointing at another
    package's directory. Resolve either case and return the raw
    template text, or None if the package doesn't exist upstream.
    """
    entry = gh_get(f"{API_ROOT}/{pkgname}")
    if entry is None:
        return None

    if isinstance(entry, dict) and entry.get("type") == "symlink":
        target_dl = entry.get("download_url")
        if target_dl:
            with urllib.request.urlopen(target_dl, timeout=30) as resp:
                target_path = resp.read().decode().strip()
        else:
            target_path = None
        if not target_path:
            return None
        real_pkg = os.path.basename(target_path.rstrip("/"))
        return resolve_template(real_pkg)

    # It's a directory containing entries including `template`
    tmpl_entry = gh_get(f"{API_ROOT}/{pkgname}/template")
    if tmpl_entry is None or "content" not in tmpl_entry:
        return None
    return base64.b64decode(tmpl_entry["content"]).decode(errors="replace")


def local_template(pkgname):
    """Fall back to a custom template kept in this repo's srcpkgs/ for
    packages that don't exist in upstream void-packages at all."""
    path = os.path.join("srcpkgs", pkgname, "template")
    if not os.path.exists(path):
        return None
    with open(path) as f:
        return f.read()


def parse_version_revision(template_text):
    v = VERSION_RE.search(template_text)
    r = REVISION_RE.search(template_text)
    return (v.group(1) if v else None, r.group(1) if r else "1")


def main():
    normal_pkgs = read_pkg_list("packages.txt")
    large_pkgs = read_pkg_list("large-packages.txt")

    overlap = set(normal_pkgs) & set(large_pkgs)
    if overlap:
        print(
            f"::warning::these packages are listed in BOTH packages.txt and "
            f"large-packages.txt, which means they'll be processed twice: "
            f"{sorted(overlap)}. Remove them from one list.",
            file=sys.stderr,
        )
        # Keep them in large-packages.txt's treatment only, since that's
        # the safer assumption (checkpointed) if they really are large.
        normal_pkgs = [p for p in normal_pkgs if p not in overlap]

    try:
        with open(STATE_PATH) as f:
            state = json.load(f)
    except FileNotFoundError:
        state = {}

    normal_matrix = []
    large_matrix = []
    missing = []

    for pkg in normal_pkgs + large_pkgs:
        print(f"checking {pkg} ...", file=sys.stderr)
        tmpl = resolve_template(pkg)
        if tmpl is None:
            tmpl = local_template(pkg)
        if tmpl is None:
            missing.append(pkg)
            continue
        version, revision = parse_version_revision(tmpl)
        if version is None:
            missing.append(pkg)
            continue

        key = f"{version}-{revision}"
        prev = state.get(pkg)
        # state/built.json entries are now {"version": ..., "built_at": ...}
        # dicts (so the status page can read a timestamp without hitting
        # the GitHub API); tolerate the older flat-string format too.
        prev_key = prev.get("version") if isinstance(prev, dict) else prev
        if prev_key == key:
            continue  # already built at this version-revision

        entry = {"package": pkg, "version": version, "revision": revision}
        if pkg in large_pkgs:
            large_matrix.append(entry)
        else:
            normal_matrix.append(entry)

    if missing:
        print(f"WARNING: could not resolve templates for: {missing}", file=sys.stderr)

    gh_out = os.environ.get("GITHUB_OUTPUT")
    lines = [
        f"normal_matrix={json.dumps(normal_matrix)}",
        f"large_matrix={json.dumps(large_matrix)}",
        f"has_updates={'true' if normal_matrix else 'false'}",
        f"has_large_updates={'true' if large_matrix else 'false'}",
    ]
    print("\n".join(lines))
    if gh_out:
        with open(gh_out, "a") as f:
            f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
