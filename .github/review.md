# Reviewing pull requests

How Claude reviews a pull request to upaa. `.github/workflows/review.yml` runs it. The project's rules are in `CLAUDE.md`; read it first.

## What to look for

- Bugs: wrong behavior, crashes, races between the PTY read thread and the main thread, leaks, errors that are dropped.
- Broken rules from `CLAUDE.md`, above all:
  - Code added where changing, removing, or hooking into existing code would do, or code left behind after its premise changed.
  - Launch options, public functions, or hooks added only for checking or measuring.
  - A workaround stacked on a problem instead of a fix at its cause.
  - Swift and Zig crossing per cell instead of per frame or per chunk, an `export fn` outside `core/src/root.zig`, or `root.zig` changed without the header in `Sources/CUpaaCore/`.
  - The cell layout changed in only some of `core/src/render/Cell.zig`, `UpaaCell`, and the shader `Cell`.
  - A libghostty-vt function that is not in the `vt-1.0.2` headers.
  - The version number written anywhere other than `build.zig.zon`.
  - References in `tests/snapshots/` replaced without a drawing change that explains them.
- Claims in the description that the diff does not back: something said to work that was not run, wrong line counts, or a missing `Closes #N`.

Skip style, naming taste, and formatting.

## How to post

- One inline comment per finding, on its line, saying what goes wrong and when.
- Then one summary as a review: each finding in a line, or "No findings".
- Write in Japanese. Do not change any file.
