# Verification status

Latest checks on 2026-11-18 with macOS 27.2. Earlier Wispr Flow and Claude Code checks are retained below. Sound quality and checks that need a person's voice remain human checks.

## Faster speech setting — 2026-11-18

- The user found all three comparison voices too slow. The local settings had `speechRate: 1.0`; only that value was changed to `1.5`, with an atomic write and a decoded JSON comparison confirming every other value was preserved. The selected online engine and Korean SunHi voice remain unchanged. Repository defaults remain at `1.0`.
- The installed CLI exported `build/voice-preview/sunhi-numbered-ko-1.5x.mp3` with the same question text as the previous SunHi comparison. Its `AVAudioPlayer` validation succeeded. The old sample is 13.248 seconds; the faster sample is 8.856 seconds, about 33% shorter. This is synthesized at the configured rate, rather than sped up by an audio player. The files were checked programmatically, not audibly reviewed for naturalness.
- `SessionCoordinator.startNext()` loads settings for each new question, and menu/CLI voice previews also load settings at invocation. The next question therefore uses the updated rate without reinstalling or restarting. Before and after the change the installed app was idle, the two watchers were running, and microphone permission was `granted`. No question panel, microphone or Wispr recording was started for this export.
- No application source or binary changed, so no build or test rerun was needed. This adjustment addresses speaking speed; perceived voice quality and a real spoken-answer test still require the user's review.

## Korean option pronunciation and voice comparison — 2026-11-18

- The real question at 23:49:48 KST used `ko-KR-SunHiNeural`: the installed app logged online synthesis at 23:49:48.944 and online playback at 23:49:50.290, with no offline fallback. It was cancelled at 23:49:58.898 when the CLI client disconnected, so this was not a completed dictation test. The user reported that the voice still sounded awkward and that numbered options sounded like repetition counts.
- Generated Korean option numbers now use explicit Sino-Korean words: `일 번`, `이 번`, `삼 번`, through `십이 번` in the regression case. Both online and offline engines receive this text. Labels, displayed option numbers and answer matching are unaffected. This fixes the ambiguous TTS input; actual pronunciation and perceived naturalness still require listening.
- `tts preview --voice ONLINE_VOICE` tries an online voice without saving it. Three samples were exported with the same text and rate 1.0, using the release CLI. They opened successfully in `AVAudioPlayer` and `afinfo` (mono, 24 kHz, 48 kbps). No panel, microphone or Wispr Flow was started, and the samples were not audibly reviewed by the agent:

  | File in `build/voice-preview/` | Voice | Duration |
  | --- | --- | --- |
  | `sunhi-numbered-ko.mp3` | `ko-KR-SunHiNeural` | 13.248 s |
  | `hyunsu-numbered-ko.mp3` | `ko-KR-HyunsuMultilingualNeural` | 12.768 s |
  | `injoon-numbered-ko.mp3` | `ko-KR-InJoonNeural` | 16.224 s |

  Text: 오늘 저녁으로 무엇을 드시고 싶으세요? 일 번, 파스타. 이 번, 초밥. 삼 번, 샐러드. 원하는 메뉴를 말씀해 주세요.

- Hyunsu's first export failed or timed out; one retry succeeded. Voice availability is not guaranteed. The saved engine remains online and the saved Korean voice remains SunHi while the user compares samples. The settings SHA-256 stayed `46fa2339643a0aa5f40b9f1da93dc393fe047c33b8468b4e8ded255b0d7621c8` throughout the previews and install.
- `./scripts/test.sh` passed all 68 tests (49 core, 19 AppKit/subprocess). `git diff --check` and release signing verification passed. The final build and installed executable have SHA-256 `d43560fe2339a42563b04e064c534f4d79281151b8ffdf7a5f8a3b7d3a0d0fd8`. Installed with `./scripts/install.sh --no-hooks`; Claude settings SHA-256 remained `13e9dcdf4aa356a11178e36bd9ef790a77b441092312d07516543c470a984e0e`. The app is idle with both watchers running. The rebuild again reset microphone permission to `notDetermined`; a person must grant it for automatic end-of-speech detection. Voice sample playback does not need this permission.

## Configurable neural voices — 2026-11-18

- New installations and old configuration files default to offline macOS TTS. The menu and `tts use system|edge` choose the engine. Online voices are opt-in and use the separately installed `edge-tts==7.3.1` Python client. Korean uses `ko-KR-SunHiNeural`, English `en-US-EmmaMultilingualNeural`; both can be changed per language. Online question text goes to Microsoft, while VoiceQuestion does not send the microphone input or dictated answer to this TTS service.
- The real service returned both configured voice names. The release executable exported a Korean MP3 (7.944 seconds) and an English MP3 (5.136 seconds). Both opened successfully with `AVAudioPlayer` and `afinfo`: mono, 24 kHz, 48 kbps. No microphone or Wispr Flow was started for these previews.
- A real neural synthesis and playback ran at volume zero and reached `edge playback finished success=true`. A deliberately missing Python runtime fell back to macOS speech, then reached `system playback finished`. The temporary synthesis directories were removed afterward. This verifies the playback lifecycle, not perceived sound quality.
- New subprocess tests use local fixtures without network or audio: text travels on stdin rather than shell arguments; shell characters and Korean text are preserved; temporary audio directories are private; missing/failing runtimes complete once; timeout deletes partial audio; cancellation cannot invoke a completion; replacing synthesis ignores the old process's exit. A menu test constructs the menu without showing it and confirms both choices, one checked engine and a preview action. Configuration tests preserve old settings and keep malformed/unknown engines offline.
- `./scripts/test.sh` passed all 67 tests (48 core, 19 AppKit/subprocess). The release build was installed with `./scripts/install.sh --no-hooks` while the app was idle. The installed executable and build both have SHA-256 `81a3b68c30d4d689ad20db7d57cdb44cf43bc214099e8d6bbc5f75493027b7d9`; `codesign --verify --strict` passed. The Claude settings hash is unchanged. The app is idle and both watchers are running. This Mac is explicitly configured for the online engine; repository defaults remain offline.
- Reinstalling the ad-hoc-signed app reset microphone permission from `granted` to `notDetermined`. A person must allow it again for automatic end-of-speech detection. Voice-only previews do not need this permission.
- Human checks remaining: listen to the exported samples; try the menu on screen; confirm that neural playback, a physical option click and dictation cooperate in a real question. The automatic tests do not open a microphone, change focus or show a panel.

## One-click answers and the symbol panel — 2026-11-18

- A plain click on an option (or ⌘1…⌘9) now answers with it on every question, including those that allow several options. ⌘-click or ⇧-click collects options instead, and ↑ or Return sends them. This replaces the multi-select behavior described in the section below.
- The panel's status line, hint line, answer preview, counter, placeholder, level meter and Skip / Send buttons are gone. Their place is taken by the asking app's icon, progress dots, a state symbol, a live waveform, a countdown ring on the send button, a star for the recommended option and check marks on chosen cards. One line of text remains for what a symbol cannot say (Wispr Flow is not running, or did not start recording; no microphone level, so press Return when done).
- `./scripts/test.sh` passed all 60 tests (47 core, 13 AppKit). The AppKit tests drive a real `QuestionSession` behind a panel that is never put on screen, with speech off and Wispr Flow and the microphone excluded: a plain click on a multi-select question answers with that option; ⌘/⇧-clicks collect, toggle and are sent together with the full labels in option order; a plain click after collecting sends only the clicked option; a ⌘-click on a single-choice question still answers; ✕ skips; typed text is sent as free text. They also check that the only text fields on the panel are the asker, the question and the options in every state, that the countdown ring runs only while confirming, and the waveform's bars.
- Every state was drawn offscreen (`VQ_SNAPSHOT_DIR`) and looked at: reading, listening with the waveform, transcribing, confirming with the ring and check marks, voice input unavailable with its notice, and a long typed answer that wraps.
- The release build answered a simulated question end to end in a separate headless instance (own socket, config and log; no audio, no window): "the second one" → `Blue (Recommended)`, and "skip" → skipped. The agent still receives the full label, marker included.
- Built and installed with `./scripts/install.sh --no-hooks` after confirming that no question was active. The app and login item restarted; the installed executable's SHA-256 matches the build, its signature verifies, both watchers are running and the existing Claude Code hook was left alone. The rebuild reset the microphone permission to `notDetermined`; until it is allowed again the end of an answer is not detected and the panel asks for Return instead.
- Not checked by a person yet: the look on screen with the blur behind it, the symbol animations (speaker, three dots), hover highlights and tooltips, the ring's timing against the real 2-second send, the waveform with a real microphone, and a physical ⌘-click.

## Option-click fix — 2026-11-18

- Reproduced the click-routing defect with a hidden AppKit panel: hit testing returned the number/title/description labels or the padding's stack view rather than the option row. The row also allowed window-background dragging. Both regression tests failed before the fix.
- The whole card now routes mouse input to the option row, which disables background dragging. The regression tests pass for the number, title, description and both side paddings, first-mouse acceptance, one callback per click, and no hit outside the card.
- `./scripts/test.sh` passed all 46 tests (44 core tests and 2 AppKit tests). These checks never show a window, move the pointer, activate an app or start a microphone. A physical mouse click in the installed app still needs user confirmation.
- Single-choice clicks already commit immediately in `QuestionSession.panelDidPickOption`; multi-select clicks toggle choices until Send / Return. That behavior was unchanged.
- Built and installed the fix with `./scripts/install.sh --no-hooks`. The app and login item restarted successfully; existing hooks were retained. The new build also includes the previously added logo icon. The installed executable's SHA-256 matches the build, and its signature verifies. Microphone permission was initially `notDetermined` during installation and was `granted` on the subsequent status check; both watchers were running and no question was active.

## Verified

| Item | How |
|---|---|
| 47 unit tests | `./scripts/test.sh`: answer matching (options, positions, Korean numerals, several choices, skip), what a click on an option does, the "(Recommended)" marker, the end-of-speech state machine, hook input and output, installing and removing hooks (backup, existing hooks kept), the Codex and Aside log parsers, Wispr history lookup, socket IPC |
| Claude Code accepts the hook's answer | In a real Claude Code session (SDK) with the hook installed, `AskUserQuestion` was called and the answer arrived in the tool result without a question dialog (with `VQ_SIMULATE_TRANSCRIPT` in place of dictation) |
| It falls back to the app's own question dialog | With `VQ_DISABLE=1`, with the app not running, and with the answer "건너뛰기" ("skip"), the hook printed nothing and Claude Code asked for its own question dialog |
| The panel does not push aside the app you are using | The frontmost app did not change while the panel was showing |
| The panel receives keyboard input | With another app frontmost, system-wide key events reached the panel |
| Wispr Flow starts and stops automatically | When the app turns dictation on through the deep link, Wispr Flow starts recording (checked through CoreAudio), and turning it off adds one entry to the Wispr history |
| When nothing is said | Finishing with Return when nothing was recognized asks again, listens once more, then skips (`no_transcript`). Without the microphone permission, when nobody answers, it skips after the time limit without asking again (`no_speech`) |
| The answer arrives by paste | Right after dictation ended, ⌘V was sent to the panel with "두 번째" ("the second one") → matched to option 2 → 2-second confirmation → answered (synthetic key events in place of Wispr) |
| Release app bundle | Built with `./scripts/build.sh`, signature verified |

## Not yet verified

| Item | Why | How to check |
|---|---|---|
| A real voice → Wispr Flow dictation → answer | Needs a person's voice | Tests 2, 3 and 7 in the README |
| The symbol panel on screen, and real clicks on it | The tests draw it offscreen and click it with synthetic events; nobody has looked at the installed panel or clicked it by hand since the change | Tests 2 and 11 in the README |
| Automatic end-of-speech detection (microphone level) | Only the user can grant the microphone permission. The logic is covered by unit tests only | Test 2, `vq miccheck` |
| Quality and volume of the spoken question | Only run with the sound off | Test 2 |
| Clipboard delivery for ChatGPT and Aside, and the experimental `paste` / `resume` / `steer` | Needs a live question card. Only the parsers are unit-tested | Test 9 |
| Codex `PreToolUse` hook | Runs only once the hook is trusted in the ChatGPT app | `vq hooks install --codex`, then trust it in the app |
| Claude desktop Code tab | Checked only by reading the app's code | Test 7 in the Code tab |
| The voice flow stops when you answer in the app | Needs a real question dialog | Answer in the original app while the voice panel is showing |
