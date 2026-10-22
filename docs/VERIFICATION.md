# Verification — 2026-09-24

## Passed

- `bash scripts/test.sh`: 29 tests, 6 suites, zero skips, exit 0. Evidence: `.omo/evidence/tests-aiff-fixed.log`.
- `bash scripts/build-app.sh`: release build and staged app signing, exit 0. Evidence: `.omo/evidence/build-aiff-fixed.log`.
- `codesign --verify --deep --strict build/Speech2Text.app`: exit 0.
- Actual signed app, production `--audio-file` route, key saved in the app's Keychain: Soniox recognized the generated Korean speech as **안녕하세요, 오늘은 맥에서 음성으로 글을 쓰고 있습니다.** No fixture response or synthetic transcript was injected. Evidence: `.omo/evidence/recognition-midpoint.png`.
- Actual notch Copy button: clipboard matched the recognized text exactly; frontmost app remained Ghostty. Evidence: `.omo/evidence/copy-result.png`.
- Actual notch Paste without current-binary permission: permission explanation appeared, transcript remained available, no text was sent. Evidence: `.omo/evidence/paste-no-permission.png`.
- Native settings and notch rendered on the real desktop. Settings expose permission request, privacy settings links, automatic-input toggle, recording and paste shortcuts. Evidence: `.omo/evidence/app-initial.png`.
- Private GitHub repository: `floweredao/Speech2Text`, `isPrivate=true`; no Actions workflows.

The generated audio tests transcription and conversion, not physical microphone pickup.

## Bug reproduced and fixed

AIFF input read past its final frame and raised `NSOSStatusErrorDomain -39` (`eofErr`). A production-converter regression reproduced the error before the fix. Reads now stop at the remaining frame boundary. The same test and real signed-app recognition pass after the fix.

## Permission diagnosis and user handoff

The user took over OS permission setup and automatic-input/paste testing. No permission database was modified and no setting was enabled by automation.

The host runs macOS 27.0 (26A428). A read-only system TCC query showed `kTCCServiceAccessibility`, client `local.speech2text.app`, `auth_value=2`. However, the stored requirement was for an earlier ad-hoc binary:

- Approved binary: `a90fa9585b39ef12a9471b049b424937fd39a782`
- Current signed app: `fd87364517b24570da2209752d7a38bcf4040412`

Thus an enabled list entry did not authorize the rebuilt binary. The user was directed to remove/re-add the current app. The current executable is frozen while the user completes setup.

**Not claimed as passed:** automatic insertion into TextEdit/Terminal/browser/Notes, Paste after permission approval, physical microphone recording, multi-monitor hot-plug and VoiceOver checks. These require the user-owned manual validation still in progress.

## Tooling and cleanup

Default Command Line Tools SwiftPM could not find Testing/TestingMacros. `scripts/test.sh` supplies the installed framework, plugin and runtime search paths. The native backend emits a deprecation warning. Release builds also emitted CLT developer search-path/arclite warnings. None was suppressed. LSP diagnostics timed out; actual Swift compilation and tests provided code diagnostics.

No reviewer gate was triggered; this was a bare ultrawork run. Self-review checked the source, cancellation/finalization tests, typed UI-state contract, absence of automatic credential sharing, signature, and actual recognition/copy/permission-denied evidence.

All build/test/recognition monitors have terminated. Temporary desktop captures and the UI worker's temporary typecheck stubs were removed. The app remains running for the user's requested setup, and the disposable TextEdit QA documents are left for their manual input tests. These are handed-off resources, not background QA jobs.

Screenshots and generated audio remain local under the git-ignored `.omo/evidence` directory; they are not published to GitHub.


# Verification — 2026-09-25 repair round (live typing, notch UI, error detail)

## Passed

- `bash scripts/test.sh`: 57 tests, 10 suites, zero skips. Evidence: `.omo/evidence/repair/final-tests.log`.
- `bash scripts/build-app.sh`: release build signed with the stable Apple Development identity, `codesign --verify --deep --strict` exit 0. Rebuilds no longer invalidate the approved control permission (TCC requirement now matches the certificate, not a per-build hash).
- Soniox error detail: a failing regression reproduced the old generic `Soniox server error`; the reducer now surfaces the provider code and message.
- Live typing into TextEdit (signed app, production Soniox, real-time-paced audio through the same PCM pipeline as the microphone): 19 successive document states over ~8 s, text appeared while audio played, final sentence inserted exactly once with no double space. Evidence: `.omo/evidence/repair/live-clean-states.tsv`, `live-clean-final.png`.
- Live cancel: mid-run text was removed and the document returned byte-for-byte to its pre-run content; notch reported the erase. Evidence: `.omo/evidence/repair/live-cancel.png`.
- Focus-change guard: when focus moved to another app during a run, live typing stopped and the result stayed in the notch instead of typing into the new app.
- Keyboard fallback (terminals, Korean 2-set IME active): per-process key events typed Hangul correctly and backspaces removed whole syllables at a zsh prompt.
- Notch: compact capsule when idle, content-sized result panel (no fixed empty block).

## Not claimed

- Physical microphone accuracy (speaker/mic distance prevented acoustic playback tests; the microphone capture path was exercised only up to "listening").
- An end-to-end app run into a terminal: the attempt was pre-empted by focus moving to the user's full-screen terminal, which exercised the guard instead.
- The QA sample produced no mid-sentence recognition revisions; correction logic is covered by unit tests and by the real-surface cancel deletion, which uses the same replacement path.


# Verification — 2026-10-22 HIG fix round

## Passed

- `bash scripts/test.sh`: 115 tests, 17 suites, zero skips, exit 0.
- Menu bar menu: "받아쓰기 취소" (enabled only while busy) and "마지막 받아쓰기 복사" (enabled only when the overlay offers copy) were added, plus an optional cancel shortcut. Settings saved before the cancel action existed still load (`ShortcutTests.settingsSavedWithoutCancelActionKeepTheirShortcuts`).
- Overlay text uses system text styles; only the two icons keep a fixed point size. The transcript scroll cap is measured as five lines of its own style (99 pt for title3 in an offscreen render).
- Overlay button hit areas: offscreen `NSHostingView` layout of `OverlayControlStyle` measures ≥ 28 × 28 pt for icon and text buttons (`OverlayHitAreaTests`).
- Settings warning text: WCAG contrast of `NSColor.warningText` ≥ 4.5:1 against window and control backgrounds in light and dark appearances (`SettingsColorTests`).
- Settings at 440 pt: offscreen renders of the Korean settings window and of the permission rows with English labels showed no clipping or overlap.

## Not claimed

- VoiceOver walk-through (start → record → finish → copy): needs the owner's Mac or a remote VM; the remote VM was out of quota. The DESIGN.md checkbox stays open.
- Keyboard-only run of the new menu items with Control+F8 and arrow keys on the real menu bar.
- Overlay text growing with a larger system text size: SwiftUI text styles on macOS did not change with `dynamicTypeSize` in an offscreen check, so whether the macOS text size setting reaches this app is unverified.
