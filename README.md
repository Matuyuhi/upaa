# upaa

A terminal emulator for macOS. The UI and rendering are written in Swift (AppKit, Metal), the core in Zig, and terminal emulation is handled by [libghostty-vt](https://lib.ghostty.org/vt/).

![upaa screenshot](tests/snapshots/styles.png)

## Requirements

- macOS 13 or later
- Apple Silicon (arm64)

## Status

Works today:

- Running a shell, keyboard input, window resizing
- 16-color, 256-color and 24-bit color, inverse and underline
- Japanese and other full-width text (two cells wide), and text committed from an input method

Not yet: selection and copy, paste, scrollback, mouse support, a config file.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/Matuyuhi/upaa/main/install.sh | sh
```

- Installs `~/Applications/upaa.app` and `~/.local/bin/upaa`. No administrator rights are needed.
- The download is verified against its SHA-256 checksum before it is unpacked.
- To install a specific version, set `UPAA_VERSION=v0.1.0`.

## Usage

```sh
upaa            # open the app
upaa update     # reinstall the latest release
upaa --version
```

On launch, upaa asks GitHub at most once a day whether a newer release exists. It only tells you; it never updates on its own. Set `UPAA_NO_UPDATE_CHECK=1` to turn the check off.

## Development

You need Xcode 27 (with the Metal Toolchain), Zig 0.17.x and minisign.

```sh
sh scripts/fetch-ghostty-vt.sh   # download libghostty-vt (signature and SHA-256 are verified)
sh scripts/build-app.sh          # build build/upaa.app
sh scripts/test.sh               # run all tests
```

| Path | Contents |
|---|---|
| `core/src/` | Zig core: PTY, calls into libghostty-vt, fonts and glyphs, building the data to draw |
| `Sources/UpaaKit/` | Swift: UI, keyboard input, Metal rendering |
| `Shaders/` | Metal shaders |
| `tests/` | Inputs and reference images for the screenshot tests |

The version lives only in `.version` in `build.zig.zon`. To release, bump it on `main` and run the `release` workflow in GitHub Actions; it creates the tag and the release.

Project conventions are in `CLAUDE.md` and the design history is in `docs/handoff.md` (both in Japanese).

## License

MIT (`LICENSE`). Licenses of the bundled libghostty-vt and its dependencies are in `THIRD_PARTY_LICENSES.md`.
