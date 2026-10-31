# Contributing

Bug reports and pull requests are both welcome.

## What you need

- An Apple silicon Mac running macOS 15 or later, with the Xcode Command Line Tools.
- No Soniox or Jev API key: the app builds and the whole test suite runs without one.
- `bash scripts/test.sh` passing on `main` before you change anything. The first run downloads the pinned
  sherpa-onnx libraries and the wake-phrase model into `Vendor/`.

## Reporting a bug

Open an issue that says:

- what you did, what you expected, and what happened instead;
- your macOS version, and whether the app came from a release or from your own build;
- the words you said, if speech was involved.

Never paste an API key, a recording, or a transcript you would not publish.

## Pull requests

1. Branch from `main` and name it `<type>/<short-description>`, where the type is one of `feat`, `fix`,
   `refactor`, `test`, `docs`, `chore`, `build`, `ci` or `perf`.
2. Keep one behavior change per commit, with an imperative subject: `fix: never send an empty keystroke`.
3. Add a test that fails before your change and passes after it. Tests live in `Tests/`, use swift-testing
   (`@Test`, `#expect`), and each test covers one stated behavior.
4. Run `bash scripts/test.sh`. Never skip, disable, or weaken a test to make the suite green.
5. In the pull request, say what changed, why, and what you ran to prove it.

## House rules for the code

- Swift 6 language mode with strict concurrency. Keep UI types `@MainActor` and models `Sendable` instead of
  silencing a concurrency warning.
- User-visible strings live in `Resources/ko.lproj/Localizable.strings` and
  `Resources/en.lproj/Localizable.strings`. The keys are the Korean strings, so add a key to both files.
- The app never presses Return on its own and never lets a line break reach the field it types into; see
  `LiveTextEdit.sanitize`. Keep it that way: a line break runs a command in a terminal.
- `README.md` and `README-ko.md` describe the same behavior. Change them together.
- `DESIGN.md` records the design decisions behind the app. Update it when you change behavior it describes.

By contributing you agree that your work is released under the [MIT License](LICENSE).
