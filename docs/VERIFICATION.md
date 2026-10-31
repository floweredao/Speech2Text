# Verifying a build

What to run before opening a pull request, and what each check must show. Only the last two sections need an API key.

## Automated

| Check | Command | Must show |
| --- | --- | --- |
| Test suite | `bash scripts/test.sh` | exit 0, no skipped test |
| Release build and signing | `bash scripts/build-app.sh` | exit 0, and the path of `build/Speech2Text.app` |
| Signature | `codesign --verify --deep --strict build/Speech2Text.app` | exit 0 |
| Shortcuts and Voice Control actions | `ls build/Speech2Text.app/Contents/Resources/Metadata.appintents/extract.actionsdata` | the file exists |

The first run of `scripts/test.sh` downloads the pinned sherpa-onnx libraries and the wake-phrase model into
`Vendor/`. The App Intents metadata is produced only on a Mac with Xcode.app; a build without it works but leaves the
Shortcuts and Voice Control actions out, and `scripts/prepare-update.sh` refuses to package such a build.

GitHub Actions runs the test suite on macOS for every push to `main` and every pull request, so a pull request also
carries that evidence.

## Recognition without a microphone

`--audio-file` runs a recording through the same pipeline a dictation uses, so recognition, the transcript reducer and
the voice edits can be checked without speaking:

```sh
build/Speech2Text.app/Contents/MacOS/Speech2Text --audio-file sample.wav --print-turns
```

Each turn prints as the pause before it in milliseconds (`-` for the first one), a tab, and the words the provider
finalized. A judged command adds a `jev` line with the verdict, its probability, the time and the tokens it took, and
the last line is `=>` followed by the text that would have been typed. Useful companions, which change that one run
only and never the saved settings:

| Argument | What it does |
| --- | --- |
| `--command-judge jev` / `off` | how words that sound like a command are judged |
| `--jev-key-file <file>` | use the key in that file instead of the saved one |
| `--context-terms <a,b>` / `--add-context-terms <a,b>` | replace or extend the words sent to the provider as context |
| `--no-auto-insert` | keep the result in the overlay instead of typing it |

`--check-key soniox|jev [--key-file <file>]` checks a key and prints only `KEY_VALID`, `KEY_REFUSED` or
`KEY_CHECK_FAILED <reason>`; it never prints the key.

## The wake phrase against a recording

`--wake-file <file>` listens to a recording with the on-device wake model and prints `WAKE <n> at_ms=<ms>
setup_ms=<ms>` per detection and `WAKE_TOTAL <n>` at the end. `--wake-phrase <words>` and `--wake-sensitivity
low|standard|high` override the saved settings, `--wake-realtime` feeds the audio at playback speed, and
`--wake-keyword-only` skips the on-device speech match that macOS 26 adds.

`--edit-corpus <cases.json>` runs written turns (`[{"id": "...", "turns": ["...", "..."]}]`) through the voice-edit
path and prints one JSON line per case, with how many edits were carried out and how many were asked about. It calls
the judge, so it needs a Jev key and spends on it.

## By hand

A person at the Mac has to confirm what no test can reach. An ad-hoc signed build gets a new identity on every
rebuild, so macOS asks for Accessibility again each time.

- Live typing into a native text field, a browser text box and a terminal, then **Cancel**: only the characters this
  dictation typed are removed.
- Focus moved to another app mid-dictation: live typing stops, and the result stays in the overlay.
- **Copy** and **Paste** in the overlay put the result in the field without a line break reaching it.
- The wake phrase: say it to start, and again at the end to finish.
- The microphone chosen in Settings is the one that records, including after unplugging it.
- VoiceOver: start, record, finish and copy through the overlay and the menu bar item.
