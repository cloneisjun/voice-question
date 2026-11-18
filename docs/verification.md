# Verification status

Checked on 2026-11-17 with macOS 27.2, Wispr Flow and Claude Code. Checks that need a real voice have to be done by a person, so they were left open.

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
