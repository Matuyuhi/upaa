# upaa handoff notes

Created: 2026-11-25 (same day; revised to reflect the decision on the language mix)
Target: Claude Code, which proceeds with implementation based on this document

upaa is a homemade terminal emulator for macOS only. The name went from wren to uparupa and then, on 2026-11-26, to upaa. Working directory names and similar may still contain wren.
This document separates what was decided in conversation before implementation, what was confirmed from primary sources, and what has not been confirmed.
There is no code yet.

## 1. Decisions

What the user decided. Confirm with the user before changing any of these.

| Item | Decision |
|---|---|
| Name | upaa (wren, then uparupa; changed to upaa on 2026-11-26) |
| Purpose | A terminal usable for daily work (do not stop at a minimal learning implementation) |
| Target OS | macOS only |
| Language mix | Swift and Zig. UI, IME, and Metal calls in Swift; the rest of the core in Zig |
| Drawing | Use Metal. Glyph generation uses CoreText |
| Terminal emulation core | Use libghostty-vt (stable C ABI) |
| Zig version | 0.17.x |
| Implementation | Full implementation is done by Claude Code |
| Supported macOS | 13 or later (decided 2026-11-25) |
| Architecture | Apple Silicon (arm64) only (decided 2026-11-25) |
| Project form | SwiftPM, plus one shell script that assembles the `.app` (decided 2026-11-25) |
| Where the XCFramework lives | Not included in the repository. Fetched by a script that checks its signature and SHA-256 (decided 2026-11-25) |

Zig was chosen because the user wants to write in Zig. The user was told that, on rationality alone, C needs less build effort, and the decision was made with that understood.

There is one condition. The mix assumes that "performance and rationality do not drop significantly." If it turns out not to work, the agreement is to say so clearly. M0 (section 5) is the checkpoint for this.

Options considered and not adopted:

- Cross-platform GUI: the initial wish, withdrawn when macOS-only was accepted.
- Electrobun + webview: could leave drawing, fonts, and IME to WebKit, but the expected ceiling on drawing performance and input latency is low, so it was dropped.
- Full libghostty (including drawing and fonts, such as GhosttyKit): the API is not stable, and writing our own would then make little sense, so it was dropped.
- All Swift: the simplest, but it does not match the wish to write in Zig.
- Core in C: the least build effort. Kept as the fallback if M0 fails.
- Zig also for UI and Metal calls: Ghostty does this, but it maintains a dedicated library and a wrapper layer of its own. Judged not worth the effort for a personal project.

## 2. Confirmed facts

As of 2026-11-25. Sources are noted.

### libghostty-vt version and stability

- libghostty-vt 1.0.0 was released 2026-11-06. From this version the C ABI is stable. 1.0.1 came on 11-11 and 1.0.2 on 11-24; both are mainly performance improvements. (release notes)
- libghostty-vt has its own version numbers, separate from the Ghostty app. Tags are `vt-X.Y.Z`. (`PACKAGING-LIBGHOSTTY.md`)
- ABI compatibility is guaranteed by semantic versioning and checked in CI. (the author's 1.0 article)
- Drawing, windowing, and PTY are not included. The user of the library must provide them. (Ghostling README)

### How to obtain libghostty-vt

- A prebuilt XCFramework is distributed. The location has the following form. (`PACKAGING-LIBGHOSTTY.md`)

  ```
  https://release.files.ghostty.org/libghostty-vt/VERSION/ghostty-vt-VERSION.xcframework.zip
  ```

  Each file has a `.minisig` signature. `SHA256SUMS` and `SHA256SUMS.minisig` are in the same location. The minisign public key is:

  ```
  RWQlAjJC23149WL2sEpT/l0QKy7hMIFhYdQOFy0Z7z7PbneUgvlsnYcV
  ```

- There is an official Swift example, `example/swift-vt-xcframework`. Its `Package.swift` uses swift-tools-version 5.9 and `platforms: [.macOS(.v13)]`. It references the XCFramework as a `binaryTarget` (named `GhosttyVt`), and the source uses `import GhosttyVt`.
- To build from source, 1.0.x requires Zig 0.17.x (0.16 and 0.18 do not work). `minimum_zig_version` in `build.zig.zon` is `0.17.0`.
- Building from a Git checkout requires `-Demit-lib-vt`. Without it, the Ghostty app itself gets built. To also build the XCFramework, add `-Demit-xcframework=true`.

### Zig 0.17.0

Sources are the official release notes.

- The latest stable release is 0.17.0. The release notes give no date; another article says it was published in October 2026. 0.17.1 was not found in the range searched. However, at M0 (2026-11-25) Homebrew had 0.17.1, and the local setup uses it.
- `@cImport` was removed. C headers are now imported by adding the translate-c package as a dependency in `build.zig`. The migration steps in the release notes start with `zig fetch --save git+https://codeberg.org/ziglang/translate-c#zig-0.17.x`.
- However, in M0 testing, the standard library's `std.Build.addTranslateC` still exists in 0.17.1. Apple headers (CoreFoundation, CoreGraphics, CoreText) and `<ghostty/vt.h>` could be imported without fetching an external package.
- The build system was rewritten and the `build.zig` API changed (`b.build_root` → `b.root`, etc.). Articles and samples written for 0.16 do not work as they are.
- The meaning of `@bitCast` changed. The release notes warn that for arrays and vectors the result may change without a compile error.
- The language server (ZLS) does not fully work with 0.17.0. Some features are restored; support is in progress.
- `aarch64-macos` is Tier 2. `x86_64-macos` is treated as deprecated.
- No timeline for 1.0 is given. 0.17.0 is a release that bundles five months of development.

### Confirmed in M0 (2026-11-25)

- How Swift and Zig connect: Zig builds the static library `zig-out/lib/libupaacore.a` (with compiler_rt included). The SwiftPM C target `CUpaaCore` (a hand-written C header `include/upaa_core.h` and an empty `shim.c`) links it with `linkedLibrary("upaacore")`. The search path is passed from `Package.swift` as `-L zig-out/lib`. Confirmed that both changes to only the Zig code and changes to only the C header are reflected by `scripts/build-app.sh`. First tried a `systemLibrary` target, but when the header changed, Swift was not recompiled in the debug build, so it was dropped.
- libghostty-vt: Zig imports `<ghostty/vt.h>` with translate-c and only calls the C API. The library itself comes in at the final Swift link, via `binaryTarget` (XCFramework). For the Zig test executable, pointing `addObjectFile` directly at `libghostty-vt.a` inside the XCFramework (a fat arm64 and x86_64 binary) linked successfully. Both the upaa static library and libghostty-vt contain compiler_rt, but no duplicate-symbol link errors occurred.
- From Zig, an 80x24 terminal was created with libghostty-vt, VT bytes were written, and the content was read back as plain text with the formatter (`Hello, \x1b[1;32mworld\x1b[0m!\r\nあいう` → `Hello, world!\nあいう`).
- When the target is specified as `aarch64-macos.13.0`, Zig does not search for the SDK automatically, and frameworks are not found. Passing the result of `xcrun --sdk macosx --show-sdk-path` as a search path in `build.zig` was enough. A mechanism equivalent to Ghostty's `apple_sdk` is not needed for now.
- From Zig, CoreText was called and Menlo's 'A' (glyph 36) was obtained. Through fallback, HiraginoSans-W3's U+3042 (hiragana a) was obtained (glyph 843). Checked on macOS 27.2.1 by directly launching the executable inside `.app`.
- `swift build` internally uses `sandbox-exec`, so it does not run inside the Claude Code sandbox. It was run outside the sandbox.
- Not yet understood: the `LC_BUILD_VERSION` of the final executable becomes `minos 13.0 / sdk 13.0`. An executable linked directly by Zig had `sdk 27.0`. AppKit changes its behavior based on the SDK version at link time, so this must be checked before M1.

### M1 measurements (2026-11-26)

Apple M4 Max, built-in display (3024 x 1964), macOS 27.2.1. Measured in an 80-column x 24-row window while actually drawing. Method: `upaa --bench-cat <file>` and `upaa --bench-keys` (`Sources/UpaaKit/App/Automation.swift`).

| Item | Result |
|---|---|
| `cat` of 50 MB of text (base64, 100 characters per line) | 0.45–0.67 s (75–110 MB/s). Measured 3 times; the first was slower |
| Frames drawn during that time | 56–80 |
| Frame assembly (CPU side: from Zig writing cells until Swift issues the draw commands) | release average 0.13–0.16 ms; debug average 0.31–0.33 ms |
| From key press until a frame showing that character appears on screen | median 23–28 ms; maximum 31–36 ms (60 times x 2) |

- The `cat` time was almost the same in release and debug. It is not caused by upaa's code; it is judged to be determined by libghostty-vt's parsing or the PTY transfer (not isolated).
- Every cell is still redrawn every frame. Frame assembly takes under 1 ms, so differential drawing (only changed rows) is not needed now.
- The key-to-display time includes the time for the shell to echo the character and the time waiting for the screen update. It does not include keyboard latency or display response. The values come in steps of about 8 ms, which is judged (a guess) to be waiting about three screen refreshes. To shorten it, a candidate is to stop using `MTKView`'s "draw at the next update" and draw immediately.
- No comparison was made with other terminals such as Terminal.app.

### How Ghostty itself is built

It is built as a Swift and Zig mix, like upaa. It can be used as a reference.

- The macOS app side is Swift (about 200 files under `macos/`). The core is Zig (about 620 files under `src/`).
- PTY (`src/pty.zig`, `src/termio/`) and CoreText-based font handling (`src/font/face/coretext.zig`, `src/font/shaper/coretext.zig`) are on the Zig side.
- Metal drawing is also on the Zig side (`src/renderer/Metal.zig`, `src/renderer/metal/`), called through the Objective-C runtime. upaa differs in writing this part in Swift.
- The mechanism for importing Apple headers into Zig is in `pkg/macos/build.zig`. It uses translate-c and `apple_sdk`, which resolves the Apple SDK path, and links frameworks with `linkFramework`.

### C API shape

Including `<ghostty/vt.h>` alone is enough. The function names below were confirmed in `include/ghostty/vt/` and `example/c-vt-*`.

- Terminal: `ghostty_terminal_new(allocator, &terminal, cols, rows)`, `ghostty_terminal_vt_write`, `ghostty_terminal_resize`, `ghostty_terminal_scroll_viewport`, `ghostty_terminal_get` / `ghostty_terminal_set`, `ghostty_terminal_free`.
- Notifications from the terminal: pass callbacks with `ghostty_terminal_set`. These include `GHOSTTY_TERMINAL_OPT_WRITE_PTY` (bytes the terminal wants to write back to the PTY), `_USERDATA`, `_BELL`, `_TITLE_CHANGED`, `_PWD_CHANGED`, `_CLIPBOARD_READ`, and `_CLIPBOARD_WRITE`. Example: `example/c-vt-effects`.
- Drawing state (render state): `ghostty_render_state_new` → `ghostty_render_state_update(state, terminal)` → row iterator (`ghostty_render_state_row_iterator_next_dirty` lets you iterate only the changed rows) → get cells → `ghostty_render_state_clean`. Example: `example/c-vt-render`.
- The render state update can also be split into two steps. Only `ghostty_render_state_begin_update` needs access to the terminal; `ghostty_render_state_end_update` can be called even while the terminal is being rewritten. This design keeps the lock shared with the IO thread short. (comment in `render.h`)
- Key input: build an event with `ghostty_key_event_*`, and convert it to bytes with `ghostty_key_encoder_encode`. `ghostty_key_encoder_set_from_terminal` reflects the terminal's modes. `ghostty_key_event_set_composing` passes whether IME composition is in progress.
- Mouse input: `ghostty_mouse_event_*` and `ghostty_mouse_encoder_*`.
- Others: paste (`ghostty_paste_encode`, `ghostty_paste_is_safe`), focus notification (`ghostty_focus_encode`), selection (`ghostty_selection_gesture_*`), search (`ghostty_search_*`), formatted output (`ghostty_formatter_*`), character width (`ghostty_unicode_grapheme_width`), Kitty images (`kitty_graphics.h`).

### Notes when referring to Ghostling

- Ghostling is the official minimal implementation (a single C file, using Raylib). Its README states that it is "not intended for daily use." It does not do text shaping.
- The Ghostty commit that Ghostling pins is `f64f4aca` (Ghostling's last commit is dated 2026-08-09). It predates 1.0.
- Five of the functions called by Ghostling's `main.c` do not exist in the `vt-1.0.2` header:

  ```
  ghostty_key_encoder_setopt_from_terminal
  ghostty_mouse_encoder_setopt
  ghostty_mouse_encoder_setopt_from_terminal
  ghostty_render_state_colors_get
  ghostty_mods
  ```

  The overall structure (PTY reads and writes, drawing loop, input flow) is a useful reference. However, function names must follow the `vt-1.0.2` header and `example/c-vt-*`.
- Ghostling's README requires Zig 0.16.x. This differs from the requirement of libghostty-vt 1.0.x (0.17.x).

## 3. Not yet confirmed

Check these before starting, or during the relevant work.

- The items checked in M0 (linking Swift with Zig, translate-c, the XCFramework contents, linking it from Zig) were moved to section 2, "Confirmed in M0".
- The minimum macOS version supported by Zig 0.17.0. The release notes say "Darwin 15.0+", but it has not been checked which macOS version that corresponds to.
- Whether libghostty-vt's Zig API is covered by the same stability guarantee as the C ABI. upaa uses the C API, so the impact is small.
- The exact scope of thread safety. The documentation of a third-party Rust binding says it is "not thread-safe unless noted otherwise." Verify by reading the official header's notes.
- Name collision for `upaa`. Not checked. (The previous name, wren, had a scripting language with the same name.)
- Performance beyond the M1 measurements (section 2, "M1 measurements"). In particular, no comparison with other terminals.

## 4. Structure proposal

The split of layers (what is written in Swift and what in Zig) has been agreed with the user. The details are estimates and may be revised during implementation.

### Layer split

| Layer | Language | Reason |
|---|---|---|
| Window, menus, tabs, settings screen | Swift | AppKit can be written directly |
| Japanese IME (`NSTextInputClient`) | Swift | Requires implementing an Objective-C protocol |
| Metal setup and draw commands | Swift | A few calls per frame, so it does not affect speed |
| Shaders | Metal Shading Language | No other choice |
| PTY creation and read/write threads | Zig | POSIX API, independent of the UI |
| Holding libghostty-vt, locking, input encoding | Zig | Only calls the C API |
| Building drawing data | Zig | Scans every cell; the heaviest loop |
| Glyph cache and atlas | Zig | Referenced for every cell from the loop above. CoreText is a C API, so it can be called from Zig |

```
[Swift] key input / IME ──> [Zig] key encoder ──> PTY (child process = shell)
                                                      │ output
                                                      v
                                        [Zig] ghostty_terminal_vt_write
                                                      │
                                                      v
                        [Zig] scan the render state and write vertex data into the Metal buffer
                                                      │
                                                      v
                                        [Swift] issue the Metal draw commands
```

### Boundary rules

- The Zig side is exposed as C functions (`export fn` and a C header), and Swift calls them as C functions.
- Crossing between languages happens per frame, or per chunk read from the PTY. Do not design per-cell callbacks to Swift. Keeping this rule matters; otherwise the mix loses its purpose.
- Swift passes a pointer to the Metal buffer, and Zig writes into it directly. No copy in between.
- Notifications from Zig to Swift (title change, bell, redraw request) are passed as callbacks, limited to low-frequency ones.

### How to use libghostty-vt

- Link the prebuilt XCFramework, and call the C API from Zig.
- The reason is to decouple the Zig version from the libghostty-vt version. If libghostty-vt is built from source, the Zig version is tied to what libghostty-vt specifies, and Zig could not be upgraded later.
- Do not use libghostty-vt's Zig API. It must be built from source with the same Zig version, and whether it is covered by the stability guarantee is unconfirmed.

### Other assessments

- For each terminal, keep one set on the Zig side: a PTY, a `GhosttyTerminal`, and a render state.
- PTY reads run on a dedicated thread. Writes to the terminal and updates of the render state are guarded by one lock. Using the two-step `ghostty_render_state_begin_update` / `end_update` shortens the time the lock is held.
- Pass Japanese IME early. If it is postponed, the rework of the input layer becomes large.
- A form that can launch as an `.app` will be needed early. A bare SwiftPM executable may behave differently from a normal app in menus and IME (not verified). Whether to use an Xcode project or SwiftPM with a script that builds the bundle is undecided.

### Burden of using Zig

The user has been told. If it becomes too heavy during implementation, report it without hiding it.

- The build machinery (translate-c, the Apple SDK path, linking with Swift) must be built by hand.
- Each Zig version upgrade will likely require fixes. The timing of the next version is not announced.
- ZLS does not fully work with 0.17.0, so editor completion and go-to-definition work poorly.

## 5. Milestones

Each stage has "criteria for being done" attached. It is best to proceed one at a time up to M2.

| Stage | Content | Criteria for being done |
|---|---|---|
| M0 | Pass the mixed foundation | (1) Call a Zig function from Swift. (2) Call libghostty-vt from Zig, create a terminal, write a string, and extract it as plain text. (3) Call CoreText from Zig and get the glyph for one character. All three work in `.app` or an equivalent form |
| M1 | Window + PTY + Metal drawing | A shell runs inside the window; `ls` and `vim` display correctly; the window follows resizing |
| M2 | Japanese display and input | Full-width characters display at 2-cell width without breaking; IME preedit text is shown; committed characters reach the shell |
| M3 | Minimum for daily use | Text selection and copy, paste, scrollback, and operation of mouse-aware apps |
| M4 | Look and settings | Font, color scheme, and window size can be changed in a config file |
| M5 | Extensions | Tabs or splits, search UI |

About M0:

- M0 also serves to check whether choosing Zig was right. If it passes, the rest is ordinary implementation.
- If any part of M0 fails, or the mechanism needed to pass becomes too large, stop there and report to the user. The candidate fallback is "core in C," and the layer split can be used as is.
- Downloading the XCFramework is an external download, so show the target URL and verification method, and get the user's confirmation before doing it.

About M1:

- Measure the time for large output (for example, `cat` of a large file) and the latency from key press to display. This lets later decisions be made with numbers.
- If Metal setup takes time, simple drawing may come first, to confirm shell operation alone. However, the shape of the data Zig produces should stay in the form Metal needs.

## 6. Items needing user confirmation

Apart from whether to publish, these were decided on 2026-11-25 (the table in section 1).

- The minimum supported macOS version (the official Swift example uses macOS 13 or later).
- Whether to target Apple Silicon only. In Zig 0.17.0, `x86_64-macos` is treated as deprecated.
- Whether to use an Xcode project or be centered on SwiftPM.
- Whether to publish or keep it for personal use (name collisions and how license notices are handled change).
- Whether to include the XCFramework in the repository or to use a fetch script.

## 7. References

- libghostty-vt documentation: https://lib.ghostty.org/vt/
- libghostty-vt release notes: https://lib.ghostty.org/vt/release-notes.html
- The author's 1.0 article: https://mitchellh.com/writing/libghostty-1-0
- Source and examples: https://github.com/ghostty-org/ghostty (tag `vt-1.0.2`, `include/ghostty/vt/`, `example/`, `pkg/macos/`, `PACKAGING-LIBGHOSTTY.md`)
- Ghostling: https://github.com/ghostty-org/ghostling
- Zig 0.17.0 release notes: https://ziglang.org/download/0.17.0/release-notes.html
- List of related projects: https://github.com/Uzaaft/awesome-libghostty
