# Similar open-source projects

Researched on 2026-11-17 (star counts and licenses as reported by the GitHub API that day). No project was found that does all of it: **detecting the question → reading it aloud → starting Wispr Flow automatically → stopping it when you finish speaking → delivering the answer to the question.** The closest ones are listed below.

## Closest

| Project | What it does | How it differs from VoiceQuestion |
|---|---|---|
| [NCSmit/notch-voice](https://github.com/NCSmit/notch-voice) (2★, no license) | A macOS notch app. Reads Claude's responses aloud and allows or denies permission requests. It also answers `AskUserQuestion` through `PreToolUse` + `updatedInput`, and uses the Wispr Flow deep links and an invisible key panel | Answers are mostly clicked or typed, and there is no automatic end-of-speech detection. Claude Code only |
| [ElMastho/Agent-Voice](https://github.com/ElMastho/Agent-Voice) (0★, GPL-3.0) | Hear what a coding agent says and answer it by voice. Supports Claude Code, Codex, Gemini CLI and Cursor, with local speech recognition on the CPU | French and English only, Windows first (macOS in beta), its own Whisper instead of Wispr Flow |
| [exTypen/agent-island](https://github.com/exTypen/agent-island) (0★, MIT) | A notch-style island at the edge of the screen. Collects permission requests and questions, and supports push-to-talk | It does not read the question aloud and turn the microphone on by itself |
| [Louis-CFM/coucou](https://github.com/Louis-CFM/coucou) (7,286★, MIT) | Watches Claude Code, Codex, Cursor, Gemini CLI and others from the Mac notch and an iPhone, with approvals from the notch and the lock screen. Questions are answered by clicking, through `PreToolUse` + `updatedInput` | No voice |
| [xvilo/claude-code-deskphone](https://github.com/xvilo/claude-code-deskphone) (2★, MIT) | Call a Claude Code session from a real analog telephone, speak the prompt, and hear the reply on the phone (Asterisk + whisper.cpp + macOS TTS) | Needs a telephone and Asterisk |
| [Vesely/skills](https://github.com/Vesely/skills) `handsfree/`, `wispr/` (28★, no license) | A collection of Claude Code skills, including hands-free and Wispr Flow skills | Skills are prompts, so they do not answer the question dialog for you |

## Voice conversation (MCP and hooks)

| Project | What it does |
|---|---|
| [mbailey/voicemode](https://github.com/mbailey/voicemode) (1,463★, MIT) | Natural voice conversation with Claude Code. It works when the model calls the MCP `converse` tool, and does not touch the `AskUserQuestion` dialog |
| [johnmatthewtennant/mcp-voice-hooks](https://github.com/johnmatthewtennant/mcp-voice-hooks) (130★, no license) | A voice input and output MCP server plugin for Claude Code |
| [paulpreibisch/AgentVibes](https://github.com/paulpreibisch/AgentVibes) (155★, Apache-2.0) | TTS for Claude Code |
| [silouone/llm-voice-loop](https://github.com/silouone/llm-voice-loop) (4★, MIT) | Speaks a summary of each Claude Code or Codex turn (Higgs Audio TTS) and takes voice input through SuperWhisper |
| [msaelices/claude-code-talk-to-me](https://github.com/msaelices/claude-code-talk-to-me) (7★, MIT) | A plugin that lets Claude Code talk with the developer by voice when it is stuck |
| [LukeSmith25/voice-cc](https://github.com/LukeSmith25/voice-cc) (1★, MIT) | Talk with Claude Code through voice attached like a peripheral |
| [jochiang/voice-mcp](https://github.com/jochiang/voice-mcp) (2★, no license) | A voice MCP server for Claude Code that uses local Whisper and Supertonic |
| [colings86/tts-plugin](https://github.com/colings86/tts-plugin) (0★, MIT) | A TTS plugin |

## Reading aloud only

| Project | What it does |
|---|---|
| [Marviel/speak_when_done](https://github.com/Marviel/speak_when_done) (41★, no license) | Tells you out loud when a task is done |
| [ZeldOcarina/claude-code-voice-notifications](https://github.com/ZeldOcarina/claude-code-voice-notifications) (13★, MIT) | Voice notifications for Claude Code with ElevenLabs TTS |
| [rachittshah/claude-voice-hooks](https://github.com/rachittshah/claude-voice-hooks) (1★, MIT) | Announces the end of a turn, permission requests and waiting states |
| [j3k0/mcp-speak-when-done](https://github.com/j3k0/mcp-speak-when-done) (0★, GPL-3.0) | An MCP server that speaks a short summary of each response |

## Controlling Wispr Flow

| Project | What it does |
|---|---|
| Raycast extension `wispr-flow` | Starts and stops dictation through the deep links |
| [pranjalv123/wispr-toggle](https://github.com/pranjalv123/wispr-toggle) (0★) | Toggles Wispr Flow's hands-free mode from the command line (bound to a mouse button) |
| [rsktaker/wispr-voice-shortcuts](https://github.com/rsktaker/wispr-voice-shortcuts) (0★, MIT) | Two voice shortcuts built on Wispr Flow (a Google search, and a Claude Code prompt in cmux) |
| [peteallport/CodexMicroWisprBridge](https://github.com/peteallport/CodexMicroWisprBridge) (1★, MIT) | A macOS bridge between Codex Micro and Wispr Flow |

## Built into the apps

- Claude Code `/voice`: dictates into the prompt input. It does not answer the question dialog automatically
- ChatGPT voice mode and dictation: made for conversation. They do not answer Codex's question card automatically
