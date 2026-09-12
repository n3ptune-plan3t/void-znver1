# void-cpu-opt

Automatically rebuilds *only the Void Linux packages you actually use*
from source, tuned for the exact CPU in your machine (default
`-march=znver1`, overridable to any `-march`/`-mtune` value GCC
accepts), whenever Void's upstream template for one of them gets a
version/revision bump.
Everything else on your system keeps coming from Void's normal binary
repo untouched.

You do exactly one manual thing: list your packages once in
`packages.txt`. Everything after that — noticing updates, rebuilding,
signing, publishing, splitting oversized builds across multiple CI
runs — is automated.

---

## How it fits together

```
you (once)              GitHub Actions (forever, automatic)
───────────              ──────────────────────────────────
xbps-query -l   ─────►   packages.txt committed to this repo
                                │
                                ▼
                   check-updates.yml   (scheduled, e.g. every 6h)
                   - reads packages.txt / large-packages.txt
                   - asks void-packages' GitHub API for each
                     template's current version+revision
                   - diffs against state/built.json
                   - dispatches build-normal.yml / build-large.yml
                     for anything that changed
                                │
                  ┌─────────────┴───────────────┐
                  ▼                               ▼
          build-normal.yml                build-large.yml
          one job per package,             checkpointed/resumable
          finishes well inside              build chain for packages
          the 6h Actions limit              that don't (LLVM, Firefox,
                                             Rust, GCC, etc.)
                  │                               │
                  └─────────────┬─────────────────┘
                                ▼
                 Both workflows build inside the official
                 ghcr.io/void-linux/void-glibc-full container
                 (native xbps-rindex, no cross-toolchain hacks),
                 then publish two things as GitHub Releases:
                 - a per-package release tagged with the package
                   name (handy for grabbing just one .xbps)
                 - a rolling "repo-glibc" release holding every
                   built package + x86_64-repodata - this IS your
                   xbps repository, served straight from Release
                   asset URLs, no gh-pages/git-history bloat
                                │
                                ▼
                     you run `xbps-install -Su`
              your laptop's /etc/xbps.d prefers this repo
              for the packages it has, falls back to Void's
              official mirror for everything else
```

## One-time setup

1. **Generate your package list** on a fresh Void install:
   ```
   xbps-query -l | awk '{print $2}' | sed 's/-[0-9].*//' > packages.txt
   ```
   Edit it down to what you actually care about optimizing — no point
   rebuilding `bash` or `coreutils` for marginal gains; focus on things
   with real CPU-bound hot loops (compilers, media codecs, compression
   tools, your dev toolchain, etc).

2. **Move genuinely large packages into `large-packages.txt`** instead
   of `packages.txt` (LLVM, GCC, Rust, Firefox, anything that takes
   hours to build). See "Large package strategy" below for what
   "large" means in practice here and where the real ceiling is.

3. **(Recommended) generate a repo signing key.** From inside the
   `void-glibc-full` container (or any Void machine), `xbps-rindex`
   can generate one for you when you first sign the repo, or you can
   pre-generate an RSA key yourself. Base64-encode the private key and
   store it as a repo secret named `REPO_SIGNING_KEY`. Never commit
   it. If you skip this, the pipeline still works — the repo is just
   unsigned, which is fine for a single personal machine but means
   `xbps-install` needs `--force`/an ignore-signature setting for it.

4. **Push this repo to GitHub as a public repo.** Public repos get
   unlimited free minutes on standard hosted runners — that's the
   whole reason this is free. (Private repos work too, but you'll
   burn through the 2,000 free minutes/month fast once large packages
   are involved.)

5. **Nothing to enable for hosting** — the rolling repo lives entirely
   as assets on the `repo-glibc` GitHub Release, which the workflows
   create automatically on first successful build.

6. On your laptop, add the repo to `/etc/xbps.d/`:
   ```
   # /etc/xbps.d/10-local-optimized.conf
   repository=https://github.com/<you>/void-cpu-opt/releases/download/repo-glibc
   ```
   Because it's listed with higher priority than the default repo,
   `xbps-install -Su` prefers your build for any package it has, and
   silently falls back to Void's official binary for everything else.

That's it — from here on you only ever touch `packages.txt` again
when you install something new you want optimized.

## Large package strategy

A single GitHub Actions job dies at 6 hours no matter what. LLVM,
GCC, Rust, Firefox, WebKitGTK etc. routinely blow past that from a
cold cache. `build-large.yml` handles this by:

1. Restoring a `ccache` + partial build-directory cache from a
   previous attempt (keyed on `package-version-revision`, not on
   attempt number, so every retry resumes instead of restarting).
2. Running the build under a watchdog that sends a graceful stop
   signal at ~5h45m, well before the hard 6h kill, so `make`/ninja
   finish their in-flight compilation units instead of getting killed
   mid-write.
3. If the build isn't finished, it tars up build state, pushes it to
   cache, and re-dispatches itself (`gh workflow run`) as attempt N+1.
4. This repeats up to `MAX_ATTEMPTS` (default 6, ≈27 hours of wall
   time spread over several runs) before giving up and reporting
   failure instead of looping forever.
5. Once a package finishes, **ccache makes subsequent revision bumps
   much faster** — you're usually only recompiling what actually
   changed upstream, not starting cold again.

**Honest caveat:** a few packages (Chromium, full WebKitGTK with
debug info, etc.) can produce build directories in the tens of GB —
bigger than GitHub's ~10GB Actions cache ceiling. Those won't fit
this pipeline cleanly on free infrastructure. Best practice: leave
truly enormous packages on Void's stock binary, and reserve this
system for things where the CPU-optimization payoff is real and the
build is finite (compilers, codecs, compression, numeric libs, your
own daily-driver toolchain).

## What changed from a naive single-job design

- **Builds and publishes are separate jobs.** `build` compiles (can run
  for hours, can run several in parallel across different packages).
  `publish` does the small, fast part that actually touches the shared
  `repo-glibc` release — download, dedupe, sign, re-upload. `publish`
  carries a `concurrency: group: void-repo-publish` lock shared across
  *both* `build-normal.yml` and `build-large.yml`, so if two package
  updates land at once, the second one's publish waits in queue instead
  of racing the first and possibly clobbering its upload. Compiling
  stays unthrottled; only the shared-state part is serialized.
- **The void-packages checkout and masterdir are kept current, not just
  cached.** A cached checkout is fetched+reset to `origin/master` every
  run, and a cached masterdir goes through `bootstrap-update` (falling
  back to a full rebootstrap if that fails) instead of being reused
  as-is indefinitely.
- **Builds run as an unprivileged `builder` user**, matching what
  `xbps-src` actually expects (it refuses to run certain steps as root).
- **You can maintain your own packages**, not just rebuild Void's.
  Anything under `srcpkgs/<name>/template` in *this* repo gets overlaid
  onto the void-packages tree before every build, taking priority over
  any same-named stock package — with subpackage symlinks generated
  automatically from `_package()` hooks. See `srcpkgs/README.md`.
- **Per-package extra repositories** are supported via
  `extra-repos/<package>.conf` for the rare case where a package needs
  build-time tooling newer than stock Void carries.
- **CPU tuning is a variable, not hardcoded.** `build_only.sh` defaults
  `CPU_MARCH` to `znver1` (this laptop's CPU) and passes it as both
  `-march` and `-mtune` to GCC/G++, plus `-C target-cpu=` to rustc. An
  exact microarchitecture like this gets you more than a generic
  `x86-64-v3` baseline would: `x86-64-v3` only guarantees AVX2/BMI1/BMI2/
  FMA/F16C/LZCNT/MOVBE, whereas `znver1` also turns on AES-NI, SHA
  extensions, and CLZERO, and tells GCC's scheduler the real instruction
  latencies/cache sizes for this chip instead of generic ones. Override
  it per-run via the repo variable `CPU_MARCH` (Settings → Secrets and
  variables → Actions → Variables) if you ever build on/for different
  hardware.
- **hostdir/binpkgs gets explicitly de-duplicated** before publishing,
  since `xbps-rindex -c` doesn't reliably prune superseded package
  files on its own.

## Recent hardening

- Container image pinned to a dated tag instead of `:latest` (bump
  deliberately in both workflow files when you want a newer image).
- `check-updates.yml` cancels an overlapping run instead of letting two
  scheduled checks dispatch the same builds twice.
- `check_updates.py` warns (and de-duplicates) if a package ends up in
  both `packages.txt` and `large-packages.txt`.
- After assembly, an informational check looks for a compiled ISA-level
  note on the built binaries via `readelf -n` — not a hard gate (plenty
  of legitimate binaries won't have one), but a place to notice if
  `-march` silently isn't reaching the build for something you expected
  to be hot code.
- `build-large.yml` deletes its own `buildstate-*` checkpoint caches once
  a package finally finishes, instead of leaving them for the 7-day
  unused-cache eviction to clear.

## Known remaining gap

`check_updates.py` detects upstream Void version bumps automatically,
and now also falls back to reading a local `srcpkgs/<pkg>/template` if
the package isn't in upstream void-packages at all — so custom packages
get picked up too. But there's no "upstream" to diff for a package that
only exists in this repo: you still bump/edit it yourself and dispatch
the build workflow by hand for it. Wiring a `push: paths: [srcpkgs/**]`
trigger to auto-dispatch on your own commits would close that loop but
isn't done yet.

## Status page

`scripts/generate_status.py` ties together the three places "what's
currently optimized and when did it last build" otherwise lives
scattered across (Releases, Actions history, `state/built.json`) into
one `STATUS.md` at the repo root - viewable directly on GitHub, no
hosting to set up.

It cross-references:
- `state/built.json` for the version-revision currently built, and
  when (`built_at`, written by the same workflow step, in the same
  commit - not looked up separately),
- `packages.txt` / `large-packages.txt` / `srcpkgs/` for everything
  tracked, including packages listed but never successfully built.

No GitHub API calls, deliberately: this runs after *every* single
package's publish, so looking up each tracked package's release via
the API on every run would cost `O(tracked packages)` API calls per
publish, and this repo can have many publishes per `check-updates.yml`
cycle - the same shape of problem as the old unconditional hostdir
seed, just in this piece instead. A per-package release's tag is
always exactly the package name (`assemble_release.sh` guarantees
that), so its URL is built directly - `https://github.com/<repo>/releases/tag/<pkg>` -
with no lookup needed.

Run it manually with `python3 scripts/generate_status.py` (needs
`REPO=<owner>/<repo>` set to build release links; without it the table
still generates, just without links).

It's wired into CI in the *publish* job of `build-normal.yml` and
`build-large.yml` - not `check-updates.yml`, which only has
`contents: read` and never touches git state; it just dispatches the
build workflows. Publish already has `contents: write`, already runs
serialized (the `void-repo-publish` concurrency group), and already
commits `state/built.json` right after computing the version that was
just built - so `STATUS.md` is regenerated and folded into that exact
same commit ("Record built version in state and refresh status page"),
rather than needing a second commit/push of its own.

## Why the void-glibc-full container

Builds run inside `ghcr.io/void-linux/void-glibc-full` (an official
image maintained by the Void project itself, also used in Void's own
CI) rather than a bare Ubuntu runner. That gives every step native
`xbps-src`/`xbps-rindex`/`xbps-install` for free — no cross-container
bootstrapping, no faking a Void chroot on a foreign distro. The one
wrinkle: GitHub's Ubuntu 24.04 runner images restrict unprivileged
user namespaces via AppArmor by default, which breaks the sandboxing
`xbps-src` uses to build without full root. `--privileged` plus
writing `0` to `apparmor_restrict_unprivileged_userns` (a host-wide,
non-namespaced sysctl, so it's visible from inside a privileged
container) is the known fix.

## What you still need to do

This is a working scaffold, not a package you can `git clone` and
trust blindly on the first run. Things worth testing before relying
on it:
- Cross-check that your chosen packages actually build cleanly with
  `-march=znver1` — a handful of codebases have inline asm or SIMD
  dispatch code that assumes baseline x86-64 and needs patching or a
  `-mno-*` carve-out.
- The large-package cache in `build-large.yml` is saved under a
  unique key per run (`buildstate-<pkg>-<run_id>`) and restored via
  prefix match, since GitHub Actions cache keys are immutable — you
  can't re-save the same key twice. This is intentional, not a bug,
  but it does mean old partial-state caches accumulate until GitHub's
  7-day-unused eviction clears them.
- Start with `packages.txt` empty except one or two small, safe
  packages, confirm the whole chain end-to-end (build → per-package
  release → rolling `repo-glibc` release → install on your laptop)
  before growing the list.
