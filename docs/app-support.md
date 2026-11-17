# How each app is detected and answered

Researched on 2026-11-17 against the versions installed on this Mac. An app update may change any of this.

## Summary

| App | Question tool | Detection | Delivering the answer | Limits |
|---|---|---|---|---|
| Claude Code (CLI, SDK, IDE extensions) | `AskUserQuestion` | `PreToolUse` hook | `updatedInput.answers` in the hook response | None. This is the official hook contract |
| Claude desktop: Code tab | `AskUserQuestion` | Same hook | Same | Not verified by running it |
| Claude desktop: Chat tab | (option UI) | None | None | There is no hook, and no way other than reading the screen |
| Claude desktop: Cowork | `AskUserQuestion` | None | None | It runs inside an isolated VM, so hooks on this Mac do not run |
| ChatGPT desktop (Codex) | `request_user_input`, `request_user_input_async` | Session log (rollout) watcher | Clipboard, and opening the thread | No public API for submitting an answer |
| Aside | Its own question tool | Daemon log watcher | Clipboard | No public API for submitting an answer |
| Clone | `AskUserQuestion` (built-in Claude Code) | `PreToolUse` hook | `updatedInput.answers` | You have to point the installer at Clone's own settings folder |

## Claude Code

- `VoiceQuestion hooks install` adds an entry with `matcher: "AskUserQuestion"` to `hooks.PreToolUse` in `~/.claude/settings.json`. The timeout is 900 seconds.
- The hook receives `tool_input.questions` on standard input and, once it has an answer, prints:

  ```json
  {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow",
    "updatedInput": {"questions": [...], "answers": {"<question text>": "<answer>"}}}}
  ```

  Claude Code takes this answer as the tool result and carries on without showing its question dialog.
- When the hook prints nothing and exits with code 0, Claude Code shows its question dialog as usual. This is the path taken when the app is not running, when it is paused, when you say "skip", and when you say nothing. The hook does not launch the app for you.
- When several questions arrive at once, they are read and answered one after another. For a question that allows several choices (`multiSelect`), the option names are joined with commas.

## Claude desktop

- The **Code tab** runs a built-in Claude Code and appears to read the hooks in `~/.claude/settings.json`. This comes from reading the app's code, not from making it ask a question.
- The **Chat tab** has no hooks. Finding the question by reading the screen (the Accessibility API) is fragile, so it is not included.
- **Cowork** runs its agent in an isolated VM, so a hook installed on this Mac does not run.

## ChatGPT desktop (Codex)

- The app is `/Applications/ChatGPT.app` (bundle ID `com.openai.codex`), and it writes session records to `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` as they happen.
- VoiceQuestion watches this folder and reads the question aloud when a `request_user_input` / `request_user_input_async` call is recorded. If the result of the same call is recorded first (you answered in the app), the voice flow stops.
- Codex has no way to take an answer from outside. So the default goes only as far as **copying the answer to the clipboard and opening the thread with `codex://threads/<id>`**. You paste it (⌘V) into the question card yourself.
- Two experimental options:
  - `"codex": {"deliver": "paste"}`: when ChatGPT is the frontmost app, presses the option's number key, or ⌘V and Return, for you. It needs the Accessibility permission, and it depends on how the question card handles keys, so an app update can break it.
  - `VoiceQuestion hooks install --codex`: adds a `PreToolUse` hook to `~/.codex/hooks.json` (existing hooks are left alone). A Codex hook cannot return an answer, so this one denies the tool call and puts the answer in the reason, which the model then reads. The hook runs only once you **trust** it in the ChatGPT app, and whether `PreToolUse` is actually called for these tools has not been verified.

## Aside

- Bundle ID `at.studio.AsideBrowser`; the CLI is `aside`. Question requests are recorded in the daemon log, `~/.aside/logs/daemon-YYYY-MM-DD.log`.
- VoiceQuestion watches this log and reads the question aloud, then copies the answer to the clipboard and brings Aside to the front. You paste it (⌘V) into the question yourself.
- Experimental: `"aside": {"deliver": "steer"}` sends the answer as a message to the running session with `aside session steer`, and `"resume"` stops the session (`session stop`) and resumes it with the answer (`session resume`). Neither answers the question card. Both add to the conversation, so the card may stay on screen. If either fails, it falls back to the clipboard.

## Clone

Clone runs Claude Code with its own settings folder (`CLAUDE_CONFIG_DIR`). Point the installer at the `settings.json` in that folder and the same hook works.

```sh
./scripts/install.sh --settings "<Clone's .claude folder>/settings.json"
```

## Controlling Wispr Flow

- On and off: the `wispr-flow://start-hands-free` and `wispr-flow://stop-hands-free` deep links, opened without bringing the app to the front. They start the same dictation session as pressing the fn key.
- Wispr Flow delivers the transcript by **pasting (⌘V) into whatever has keyboard focus**. So just before the answer arrives, the question panel takes keyboard focus to catch the paste (the app you were using stays frontmost) and gives it back afterwards.
- In case the paste did not reach the panel, VoiceQuestion reads the dictation you just made from Wispr Flow's local history (`History` in `flow.sqlite`). Wispr Flow records the final status only after it has pasted, so a row with no status, or with `processing`, is treated as still in progress.
- The end of speech is detected by measuring the input level of the microphone Wispr Flow uses. The threshold adapts to the background noise, and by default 1.6 seconds of quiet ends the answer.
