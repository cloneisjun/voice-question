# How each app is detected and answered

Researched on 2026-11-17 against the versions installed on this Mac; the Claude desktop next-step box was added on 2026-11-19 (Claude desktop 6.6395.0, Claude Code 2.1.326) and sending answers to Aside on 2026-11-20 (Aside CLI 1.26.1115). An app update may change any of this.

## Summary

| App | Question tool | Detection | Delivering the answer | Limits |
|---|---|---|---|---|
| Claude Code (CLI, SDK, IDE extensions) | `AskUserQuestion` | `PreToolUse` hook | `updatedInput.answers` in the hook response | None. This is the official hook contract |
| Claude desktop: Code tab, question dialog | `AskUserQuestion` | Same hook | Same | Seen working in the app's sessions on 2026-11-18 |
| Claude desktop: Code tab, next-step box | `mcp__ccd_turn__wrap_up` (`ask`, `actions`) | `Stop` hook that reads the session transcript | `decision: "block"` with the answer as the reason | Only boxes whose buttons are all replies. Checked with Claude Code 2.1.326 and a stand-in for the box, not yet in the app |
| Claude desktop: Chat tab | (option UI) | None | None | There is no hook, and no way other than reading the screen |
| Claude desktop: Cowork | `AskUserQuestion` | None | None | It runs inside an isolated VM, so hooks on this Mac do not run |
| ChatGPT desktop (Codex) | `request_user_input`, `request_user_input_async` | Session log (rollout) watcher | Clipboard, and opening the thread | No public API for submitting an answer |
| Aside | Its own question tool (`ask_user_question`) | Daemon log watcher | Card editor through Accessibility, then CLI message delivery when unavailable | An open, matching single-choice card can receive the label in its written-answer field when Accessibility is granted |
| Clone | `AskUserQuestion` (built-in Claude Code) | `PreToolUse` hook | `updatedInput.answers` | You have to point the installer at Clone's own settings folder |

## Claude Code

- `VoiceQuestion hooks install` adds an entry with `matcher: "AskUserQuestion"` to `hooks.PreToolUse` in `~/.claude/settings.json`. The timeout is 900 seconds. (It also adds the `Stop` entry described under Claude desktop.)
- The hook receives `tool_input.questions` on standard input and, once it has an answer, prints:

  ```json
  {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow",
    "updatedInput": {"questions": [...], "answers": {"<question text>": "<answer>"}}}}
  ```

  Claude Code takes this answer as the tool result and carries on without showing its question dialog.
- When the hook prints nothing and exits with code 0, Claude Code shows its question dialog as usual. This is the path taken when the app is not running, when it is paused, when you say "skip", and when you say nothing. The hook does not launch the app for you.
- When several questions arrive at once, they are read and answered one after another. For a question that allows several choices (`multiSelect`), the option names are joined with commas.

## Claude desktop

- The **Code tab** runs a built-in Claude Code that reads the hooks in `~/.claude/settings.json`: `AskUserQuestion` calls from its sessions reached VoiceQuestion on 2026-11-18. It also has a second way of asking, the next-step box below, which that hook never sees.
- The **Chat tab** has no hooks. Finding the question by reading the screen (the Accessibility API) is fragile, so it is not included.
- **Cowork** runs its agent in an isolated VM, so a hook installed on this Mac does not run.

### The next-step box

At the end of a turn the Code tab shows a card with a recap, sometimes a question, and buttons ("Ask the owner", "I'll prepare it", "Commit", …). This is not `AskUserQuestion`:

- The model calls the app's own tool `mcp__ccd_turn__wrap_up` with `recap`, and optionally `ask` (the question), `actions` (the buttons) and `blocked`. A button is either a reply, `{"label": "..."}`, or an app action, `{"action": "commit"}` (also `create_pr`, `merge`, `fix_ci`, …).
- The tool returns at once ("Shown in the next-step box. …"), the model writes its closing message, and the turn ends. Clicking a reply button later sends its label as an ordinary user message.

So there is no tool call to answer, and a `PreToolUse` hook on `AskUserQuestion` is never called. `VoiceQuestion hooks install` therefore adds a second entry, under `hooks.Stop` (no matcher, 900-second timeout), that runs `VoiceQuestion hook claude-stop` whenever a turn ends:

1. The hook reads the last 2 MB of the session transcript (`transcript_path` in the hook input) and looks for the turn's last `wrap_up` call. In a session that never used the box this takes a few hundredths of a second and nothing else happens.
2. It asks by voice only when the box has an `ask` and every button is a reply. The reply labels become the options. A box with an app-action button is left to the app, because a hook cannot press that button.
3. It does nothing when the box is no longer waiting: the user already sent or queued a message after it, or the turn already ended once with this box (`stop_hook_summary` in the transcript). The same box is never asked twice.
4. With an answer it prints `{"decision": "block", "reason": "... Q: <question>\nA: <answer>"}`. Claude Code hands the reason to the model as "Stop hook feedback" and the turn continues with the answer. Skipping, saying nothing, Pause, or the app not running print nothing: the turn ends as usual and the box stays as it is.
5. While the question is being asked, the hook watches the transcript. If you click a button or type in the app instead, it exits and the voice panel closes.

Limits:

- The answer reaches the model as hook feedback, not as a message typed by you. Claude Code shows this as a stop hook that "reported a problem"; that label is how a blocking `Stop` hook is displayed, not a failure.
- The box on screen is not updated by the hook. The reason asks the model to call `wrap_up` again when it finishes, which replaces the box.
- The turn does not end until you answer or skip, so the session shows as working while the panel is up.
- What the app shows while this happens has not been watched on screen yet; see [verification.md](verification.md).

## ChatGPT desktop (Codex)

- The app is `/Applications/ChatGPT.app` (bundle ID `com.openai.codex`), and it writes session records to `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` as they happen.
- VoiceQuestion watches this folder and reads the question aloud when a `request_user_input` / `request_user_input_async` call is recorded. If the result of the same call is recorded first (you answered in the app), the voice flow stops.
- Codex has no way to take an answer from outside. So the default goes only as far as **copying the answer to the clipboard and opening the thread with `codex://threads/<id>`**. You paste it (⌘V) into the question card yourself.
- Two experimental options:
  - `"codex": {"deliver": "paste"}`: when ChatGPT is the frontmost app, presses the option's number key, or ⌘V and Return, for you. It needs the Accessibility permission, and it depends on how the question card handles keys, so an app update can break it.
  - `VoiceQuestion hooks install --codex`: adds a `PreToolUse` hook to `~/.codex/hooks.json` (existing hooks are left alone). A Codex hook cannot return an answer, so this one denies the tool call and puts the answer in the reason, which the model then reads. The hook runs only once you **trust** it in the ChatGPT app, and whether `PreToolUse` is actually called for these tools has not been verified.

## Aside

- Bundle ID `at.studio.AsideBrowser`; the CLI is `aside`. Question requests are recorded in the daemon log, `~/.aside/logs/daemon-YYYY-MM-DD.log`. The questions themselves come from `aside session list --json`, where the session carries a `suspension` of kind `ask-user-question`.
- VoiceQuestion watches this log and reads the question aloud. If the suspension disappears first (you answered in Aside), the voice flow stops.
- Aside answers a question card through its daemon, which accepts that call only from Aside's own signed clients, and the CLI has no command for it. VoiceQuestion does not go around this. With `"aside": {"deliver": "send"}`, VoiceQuestion first tries the open chat’s single-choice card through macOS Accessibility. It matches the chat URL, pending question, title and option labels. It writes the selected label into the card’s empty answer field and directs Return to Aside. A submission whose result is uncertain leaves the card available for inspection. When the card or permission is unavailable, the CLI delivers a message:
  1. `aside session list --json`. If the question is no longer waiting, nothing is sent: stopping a session that has moved on would cut off its work.
  2. `aside session stop <id>`. This closes the card and ends the waiting turn; the agent's question ends as interrupted.
  3. `aside session steer <id> -- <message>`. On a stopped session this starts the next turn. The message is "Here is my answer to the question you just asked." followed by `Q:` and `A:` lines, and it appears in the conversation as your own message.
  4. The session should leave `interrupted` within a few seconds. If it does not, or any command fails, VoiceQuestion does what `clipboard` does.
- `"deliver": "clipboard"` copies the answer and brings Aside to the front; you paste it (⌘V) into the question yourself. It was the default until 2026-11-20. The earlier experimental values `resume` and `steer` are now read as `send`.

Limits:

- The message fallback closes the card as interrupted.
- Stop and steer were verified with a real pending card. See [verification.md](verification.md).
- Sessions on a remote host are not handled.

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
