<p align="center">
  <img src="docs/assets/logo.svg" width="128" height="128" alt="VoiceQuestion logo">
</p>

<h1 align="center">VoiceQuestion</h1>

<p align="center">
  <strong>Hear your AI agent's question. Answer it out loud.</strong><br>
  A macOS menu bar app that reads an agent's question to you and sends back what you say, with Wispr Flow doing the dictation.
</p>

---

When an AI agent stops to ask you something (`AskUserQuestion`), VoiceQuestion **reads the question aloud, turns on Wispr Flow dictation, turns it off when you stop talking, and passes what you said back as the answer to that question.**

## How it works

| | Step | How |
|---|---|---|
| 1 | The agent asks a question | A Claude Code hook, or a log watcher for ChatGPT and Aside |
| 2 | The question is read aloud | macOS text-to-speech, with a panel at the top of the screen |
| 3 | The microphone turns on | `wispr-flow://start-hands-free` |
| 4 | You answer, and the end of your speech is detected | Microphone input level (voice activity detection) |
| 5 | The microphone turns off | `wispr-flow://stop-hands-free` |
| 6 | Your answer reaches the agent | The hook's response, or the clipboard |

- Wispr Flow still does the dictation, so your dictionary and style settings apply. VoiceQuestion only starts and stops it in place of the fn key.
- If anything fails, or you skip, you always get the app's **own question dialog** back. VoiceQuestion never makes up an answer.

## Requirements

- macOS 14 or later, with a Swift toolchain (Xcode or the Command Line Tools)
- [Wispr Flow](https://wisprflow.ai), running. Without it the panel still appears, but voice input is skipped.

## Install

```sh
git clone https://github.com/cloneisjun/voice-question.git
cd voice-question
./scripts/install.sh
```

`install.sh` does three things:

1. Builds a release and installs it as `~/Applications/VoiceQuestion.app`
2. Registers a login item (LaunchAgent `com.cloneisjun.voicequestion`) and starts the app
3. Adds the Claude Code hook to `~/.claude/settings.json` (the existing file is backed up as `*.voicequestion.bak`)

Options: `--no-hooks`, `--no-login-item`, `--settings FILE` (also add the hook to another Claude Code settings file), `--codex-hook` (experimental Codex hook).

When macOS asks for microphone access after the install, click **Allow**. VoiceQuestion only measures the input level to notice when you have finished speaking; it does not record or store audio. It also works without the permission, but then you press Return when you finish speaking. If you do not press Return within 45 seconds, it goes ahead with whatever has been transcribed so far, or skips if there is nothing.

> Claude Code sessions that are already open do not pick up the hook. Start a new session.

A handy alias:

```sh
alias vq="$HOME/Applications/VoiceQuestion.app/Contents/MacOS/VoiceQuestion"
```

## Try it

| # | Try this | Expected result |
|---|---|---|
| 1 | `vq doctor` | App running, Wispr Flow running, microphone permission granted, Claude Code hook installed |
| 2 | Menu bar icon → **Ask a test question** (or `vq test`), then say "Pasta" ("파스타") | You hear the question, Wispr Flow starts, it stops about 1.6 seconds after you stop talking, and after a 2-second confirmation an "Answer: Pasta" message appears |
| 3 | Same question, say "the second one" or "number two" ("두 번째", "2번") | The second option is selected |
| 4 | Same question, say "skip" ("건너뛰기") | A "Skipped" message (with a real agent, its own question dialog appears) |
| 5 | Press Esc during the 2-second confirmation, edit the text, then press Return | The edited text is delivered as the answer. ⌘R lets you speak again |
| 6 | `vq ask --question "Deploy now?" --option Yes --option No --json` | The answer is printed as JSON (exit code 0 answered, 2 skipped) |
| 7 | In a new Claude Code session: "Use the AskUserQuestion tool to ask me my favorite color" | The voice panel appears in place of Claude Code's question dialog, and Claude carries on with the answer you spoke |
| 8 | Menu → **Pause**, then repeat 7 | Claude Code's own question dialog appears |
| 9 | Have ChatGPT desktop (Codex) ask a question | You hear the question, the answer is copied to the clipboard, and the thread opens. Press ⌘V in the question card |
| 10 | The flow without any sound: `vq ask --question "Color?" --option Red --option Blue --simulate "the second one"` | "Blue", with no audio |

Menu and panel text follow the system language: Korean when Korean is your first preferred language, English otherwise. On a Korean system the menu items above read 테스트 질문 실행 (Ask a test question) and 일시 중지 (Pause). The voice follows the language of each question. The sample question is in Korean (김치찌개 / 파스타 / 샐러드) whenever Korean appears anywhere in your preferred languages, otherwise in English (Sushi / Pasta / Salad).

Click anywhere on an option card, including its number, title or description. For a single-choice question, one click sends the answer immediately; there is no extra Send step. For a multiple-choice question, click to toggle the options, then press **Send** or Return. Typing an answer also requires **Send** or Return.

### What you can say

- An option's name, its position ("the first one", "number two", "the last one"), or several at once when the question allows it ("one and three")
- A free-form answer that is not one of the options. It is passed along as is.
- "skip", "pass" or "cancel" to go back to the app's own question dialog, and "again" to be heard once more

The same works in Korean: "두 번째", "2번", "마지막", "1번이랑 3번", "건너뛰기", "다시".

### Panel shortcuts

Return send · Shift-Return new line · Esc cancel or edit · ⌘R speak again · ⌘1…⌘9 pick an option

## App support

| App | Detecting the question | Delivering the answer | Status |
|---|---|---|---|
| **Claude Code** (CLI, SDK, IDE) | `PreToolUse` hook (`AskUserQuestion`) | The hook returns the answer, so Claude continues without showing its dialog | Supported |
| **Claude desktop: Code tab** | Same hook (`~/.claude/settings.json`) | Same | Expected to work, not verified |
| **Claude desktop: Chat / Cowork** | No way | No way | Not supported |
| **ChatGPT desktop (Codex)** | Session log watcher (`request_user_input`) | Copies the answer to the clipboard and opens the thread; you press ⌘V | Reading and dictation are automatic, pasting is manual. Not yet verified with a live question |
| **Aside** | Daemon log watcher | Copies the answer to the clipboard; you press ⌘V | Reading and dictation are automatic, pasting is manual. Not yet verified with a live question |
| **Clone** | Claude Code hook (its own settings folder) | The hook returns the answer | Add it yourself with `--settings` |

More detail lives in three documents:

- [docs/app-support.md](docs/app-support.md): how each app is detected and answered, and the limits
- [docs/verification.md](docs/verification.md): what has been verified and what has not
- [docs/similar-projects.md](docs/similar-projects.md): similar open-source projects

## Settings

`~/Library/Application Support/VoiceQuestion/config.json` (menu → **Open settings file**). Every key is optional, and a saved change applies from the next question.

```json
{
  "micStart": "auto",
  "speakQuestions": true,
  "speakOptions": true,
  "speechRate": 1.0,
  "speechVolume": 1.0,
  "autoSendDelaySeconds": 2.0,
  "vad": { "endSilenceSeconds": 1.6, "noSpeechTimeoutSeconds": 12 },
  "codex": { "enabled": true, "deliver": "clipboard" },
  "aside": { "enabled": true, "deliver": "clipboard" }
}
```

| Key | Default | Description |
|---|---|---|
| `enabled` | `true` | When off, the hook does nothing (the same as Pause in the menu) |
| `micStart` | `auto` | `auto`: with headphones the microphone opens together with the question, with speakers it opens once the question has been read. `immediately` or `afterSpeech` pins one behavior |
| `speakQuestions` | `true` | When off, there is no sound, only the panel and the microphone |
| `speakOptions`, `speakOptionDescriptions` | `true`, `false` | Also read the options, and their descriptions |
| `speechRate`, `speechVolume` | `1.0` | Speaking rate multiplier, and volume (0 to 1) |
| `voices` | `{}` | A voice per language, for example `{"ko": "com.apple.voice.premium.ko-KR.Yuna"}` |
| `autoSendDelaySeconds` | `2.0` | Time to review the transcribed answer before it is sent. `0` sends right away |
| `retriesOnEmpty` | `1` | How many times to listen again when nothing was recognized |
| `skipWhenMicBusy` | `true` | Skip while another app (a call, a recording) is using the microphone |
| `focus` | `onAnswer` | `onAnswer`: the panel takes the keyboard only just before your answer arrives. `immediately`: as soon as the question appears |
| `panelActivation` | `nonactivating` | Set to `activate` if the transcribed text does not land in the panel |
| `vad.endSilenceSeconds` | `1.6` | This much silence means the answer is finished |
| `vad.noSpeechTimeoutSeconds` | `12` | Skip when nothing is said for this long |
| `vad.maxAnswerSeconds` | `90` | Longest answer |
| `vad.enabled`, `vad.device`, `vad.speechThresholdDb`, `vad.noiseMarginDb` | `true`, `auto`, automatic, `10` | Fine-tuning for end-of-speech detection (check the levels with `vq miccheck`) |
| `wispr.transcriptTimeoutSeconds` | `12` | How long to wait for the transcript after the microphone is turned off |
| `codex.deliver` | `clipboard` | `clipboard` / `paste` (also presses ⌘V and Return for you; experimental, needs the Accessibility permission) / `none` (read aloud only) |
| `aside.deliver` | `clipboard` | `clipboard` / `resume` or `steer` (delivers through the `aside` CLI; experimental) / `none` |

Environment variables: `VQ_DISABLE=1` (turn the hook off), `VQ_SIMULATE_TRANSCRIPT=text` (answer with this text, without audio), `VQ_LOG_TRANSCRIPTS=1` (write transcripts to the log), `VQ_SOCKET` / `VQ_CONFIG` / `VQ_LOG` (a separate instance for testing).

## Troubleshooting

- **Checking the state**: `vq doctor` and `vq status`. The log is at `~/Library/Logs/VoiceQuestion/voicequestion.log` (menu → **Open log**)
- **macOS asks for the microphone again after a rebuild**: the app is signed ad hoc, without a certificate. If the prompt does not appear, run `tccutil reset Microphone com.cloneisjun.VoiceQuestion`, then choose **Request microphone access…** in the menu. If you have a signing certificate, use `CODESIGN_IDENTITY="Apple Development: …" ./scripts/install.sh`
- **It cuts you off too early, or waits too long**: adjust `vad.endSilenceSeconds`
- **A noisy room hides the end of your speech**: look at the levels with `vq miccheck` and pin `vad.speechThresholdDb`, or press Return when you finish
- **The transcript lands in the app you were using, not in the panel**: set `"panelActivation": "activate"` or `"focus": "immediately"`
- **On speakers, the spoken question leaks into the dictation**: with the default (`micStart: auto`) the microphone opens only after the question when you are on speakers. If you changed it to `immediately`, change it back
- **Wispr Flow is not running**: only the panel appears, and it skips after 45 seconds (use the app's own question dialog)
- **Nothing happens in Claude Code**: check that you started a new session, run `vq hooks status`, and make sure the app is running. When the app is not running, the hook quietly steps aside and the usual question dialog appears

## Privacy

- Microphone: only the input level (dB) is computed. Audio is never recorded, stored or sent anywhere. Wispr Flow does the dictation.
- Wispr Flow history (`flow.sqlite`): read-only, and only to look up the dictation you just made when its paste did not reach the panel.
- By default the log does not contain what you said, only its length in characters.
- No network access. The app and the hook talk only over a local Unix socket.

## Uninstall

```sh
./scripts/uninstall.sh          # removes the app, the login item and the hooks
./scripts/uninstall.sh --purge  # also the settings, the logs and the microphone permission
```

## Development

```sh
./scripts/test.sh        # core logic and AppKit option-click regression tests
./scripts/build.sh       # build/VoiceQuestion.app
./scripts/make-icon.sh   # Resources/AppIcon.icns, after changing the logo
```

```
Sources/VQCore/         Logic without AppKit: models, IPC, answer matching, end-of-speech detection, hook and log parsers
Sources/VoiceQuestion/  Menu bar app and CLI: panel, session state machine, TTS, Wispr control, log watchers, delivery
Tests/VQCoreTests/      Unit tests
Tests/VQUITests/        Option-card mouse routing (hidden windows, no microphone)
Resources/              Info.plist and the app icon (AppIcon.icns, generated from the logo)
scripts/                build / install / uninstall / test / make-icon
docs/assets/            Logo (logo.svg is the source, logo.png is a 512 px render)
```

A single executable is both the menu bar app and the CLI. The hook (`VoiceQuestion hook claude`) passes the question to the running app over a Unix socket, waits for the answer, and prints it as JSON that Claude Code understands. If the app is not running, or you skip, it prints nothing and exits, so the agent shows its own question dialog.
