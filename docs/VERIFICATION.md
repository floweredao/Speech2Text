# Verification — 2026-09-24

## Passed

- `bash scripts/test.sh`: 29 tests, 6 suites, zero skips, exit 0. Evidence: `.omo/evidence/tests-aiff-fixed.log`.
- `bash scripts/build-app.sh`: release build and staged app signing, exit 0. Evidence: `.omo/evidence/build-aiff-fixed.log`.
- `codesign --verify --deep --strict build/Speech2Text.app`: exit 0.
- Actual signed app, production `--audio-file` route, explicit source-key import: Soniox recognized the generated Korean speech as **안녕하세요, 오늘은 맥에서 음성으로 글을 쓰고 있습니다.** No fixture response or synthetic transcript was injected. Evidence: `.omo/evidence/recognition-midpoint.png`.
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
