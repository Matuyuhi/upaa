# upaa

A homemade terminal emulator for macOS only. Written in Swift (AppKit) and Zig. Terminal emulation itself is left to libghostty-vt (stable C ABI). The goal is to be usable for daily work.

The background, confirmed facts, unconfirmed items, and milestones are in `docs/handoff.md`. Read it before starting.

## Decided

- Target is macOS 13 or later on Apple Silicon (arm64) only. No cross-platform support.
- The language is a mix of Swift and Zig. UI, IME, and Metal calls are in Swift. The rest of the core (PTY, libghostty-vt calls, building drawing data, glyph cache) is in Zig. Zig is 0.17.x.
- Build uses SwiftPM and `scripts/build-app.sh` (`zig build` → `swift build` → `build/upaa.app`).
- The prebuilt libghostty-vt XCFramework is fetched by `scripts/fetch-ghostty-vt.sh`. It is not included in the repository.
- Use libghostty-vt 1.0.x. The full libghostty, including drawing and fonts (such as GhosttyKit), is not used because its API is not yet stable.
- Drawing uses Metal. Glyph generation uses CoreText.
- Display of Japanese text and IME are not postponed.

## Layout

- `core/src/` — Zig core. Functions exported to C (`export fn`) go only in `root.zig`. The implementation goes in folders by role.
  - `c/` headers imported with translate-c, `term/` terminal session (PTY, read thread, libghostty-vt), `font/` font and glyph atlas, `render/` building cell data for Metal.
- `Sources/CUpaaCore/` — C headers for the Zig functions. Edit them together with `root.zig`.
- `Sources/UpaaKit/` — Swift implementation (`App/`, `Terminal/`, `Render/`). `Sources/upaa/` only launches the app.
- `Shaders/` — Metal shaders. `scripts/build-app.sh` compiles them and puts them into the `.app`. The layout of cell data must match in three places: `core/src/render/Cell.zig`, the C header `UpaaCell`, and the shader `Cell`.
- To check drawing, write one frame to a PNG with `build/upaa.app/Contents/MacOS/upaa --snapshot <png> [--input <string>]` and view it.
- Tests: `sh scripts/test.sh` (Zig tests, comparison of the screens in `tests/fixtures/*.vt` against the reference images in `tests/snapshots/`, lower and upper bounds on speed). When a drawing change is intended, replace the references with `UPDATE_SNAPSHOTS=1 sh scripts/test.sh`, and commit only after checking the images. GitHub Actions (`.github/workflows/test.yml`) calls the same script.
- `swift build` and tests that use a PTY (`zig build test`) do not run inside the Claude Code sandbox.

## Implementation approach

Do not proceed by just piling on code. Avoid increasing the amount of code itself.

- Before adding code, look for a way that needs no addition. First consider whether changing or removing existing code, or hooking into an existing mechanism, can solve the problem.
- Do not add launch options, public functions, or hooks only for checking or measuring. Verify with tests or a throwaway local script. If one must stay, state the reason and get confirmation before adding it.
- When a problem occurs, do not stack workarounds. Identify the cause and fix it at the source. If a workaround must go in before the cause is identified, consult first.
- Remove code that is no longer needed because the premise changed, in the same change.
- Reports of changes state how many lines were added and how many were removed.

## Version and release

- The version is written only in `.version` of `build.zig.zon`. Zig code, Swift (`upaa --version`, update check), and the `.app`'s `Info.plist` take it from there. Do not write the number anywhere else.
- For a release, run `.github/workflows/release.yml` by hand (`gh workflow run release.yml`). It reads the number from `build.zig.zon`, runs the tests, and creates the `v<number>` tag and the Release (zip and `SHA256SUMS`). Do not type the tag by hand. After the release it calls `.github/workflows/bump-version.yml`, which moves `main` to the next patch version. For a new minor or major version, run `gh workflow run bump-version.yml -f part=minor` (or `major`) before releasing.
- Install is via `install.sh` (`curl ... | sh`). It places `~/Applications/upaa.app` and `~/.local/bin/upaa`. The contents of the `upaa` command come from `scripts/upaa-launcher.sh`.
- The update check at startup is `Sources/UpaaKit/App/UpdateCheck.swift`. It queries GitHub once a day. It only notifies; it does not update.

## Rules to follow

- Function names and usage for libghostty-vt follow the header at tag `vt-1.0.2` (`include/ghostty/vt/`) and `example/c-vt-*`, which are authoritative. Ghostling is pinned to a commit from before 1.0 and calls functions that do not exist in 1.0.2.
- In reports, separate confirmed facts from guesses. Do not write that something "works" if it was not run.
- For operations involving external downloads, publishing, deletion, or overwriting, show the target and impact and get the user's confirmation before doing them.
- Do not have the user enter credentials such as private keys or tokens.
