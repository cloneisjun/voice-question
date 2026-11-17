# Verification status

Checked on 2026-11-17 with macOS 27.2, Wispr Flow and Claude Code. Checks that need a real voice have to be done by a person, so they were left open.

## Verified

| Item | How |
|---|---|
| 44 unit tests | `./scripts/test.sh`: answer matching (options, positions, Korean numerals, several choices, skip), the end-of-speech state machine, hook input and output, installing and removing hooks (backup, existing hooks kept), the Codex and Aside log parsers, Wispr history lookup, socket IPC |
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
| Automatic end-of-speech detection (microphone level) | Only the user can grant the microphone permission. The logic is covered by unit tests only | Test 2, `vq miccheck` |
| Quality and volume of the spoken question | Only run with the sound off | Test 2 |
| `install.sh` and the login item | It installs a background program and a global hook into the user's account, so it was not run | `./scripts/install.sh` |
| Clipboard delivery for ChatGPT and Aside, and the experimental `paste` / `resume` / `steer` | Needs a live question card. Only the parsers are unit-tested | Test 9 |
| Codex `PreToolUse` hook | Runs only once the hook is trusted in the ChatGPT app | `vq hooks install --codex`, then trust it in the app |
| Claude desktop Code tab | Checked only by reading the app's code | Test 7 in the Code tab |
| The voice flow stops when you answer in the app | Needs a real question dialog | Answer in the original app while the voice panel is showing |
