# 비슷한 오픈 소스

2026-11-17에 조사했습니다(별 수·라이선스는 그날 GitHub API 기준). **질문 감지 → 읽어 주기 → Wispr Flow 자동 시작 → 말 끝에서 자동 종료 → 답을 질문에 전달**까지 전부 하는 프로젝트는 찾지 못했습니다. 가까운 것들은 다음과 같습니다.

## 가장 가까운 것

| 프로젝트 | 하는 일 | VoiceQuestion과 다른 점 |
|---|---|---|
| [NCSmit/notch-voice](https://github.com/NCSmit/notch-voice) (2★, 라이선스 없음) | macOS 노치 앱. Claude의 응답을 읽어 주고 권한 요청을 허용·거절. `AskUserQuestion`도 `PreToolUse` + `updatedInput`으로 답하며, Wispr Flow 딥링크와 보이지 않는 키 패널을 씀 | 답은 클릭·타이핑 중심이고 말 끝 자동 감지가 없음. Claude Code 전용 |
| [ElMastho/Agent-Voice](https://github.com/ElMastho/Agent-Voice) (0★, GPL-3.0) | 코딩 에이전트의 말을 듣고 음성으로 답함. Claude Code·Codex·Gemini CLI·Cursor 지원, 로컬 CPU 음성 인식 | 프랑스어·영어만, Windows 중심(macOS 베타), Wispr Flow가 아닌 자체 Whisper |
| [exTypen/agent-island](https://github.com/exTypen/agent-island) (0★, MIT) | 화면 가장자리의 노치형 섬. 권한 요청과 질문을 모아 보여 주고 눌러서 말하기(push-to-talk) 지원 | 자동으로 읽어 주고 마이크를 켜는 흐름이 아님 |
| [Louis-CFM/coucou](https://github.com/Louis-CFM/coucou) (7,286★, MIT) | Mac 노치와 iPhone에서 Claude Code·Codex·Cursor·Gemini CLI 등을 지켜보고 노치·잠금 화면에서 승인. 질문은 `PreToolUse` + `updatedInput`으로 클릭해서 답함 | 음성 없음 |
| [xvilo/claude-code-deskphone](https://github.com/xvilo/claude-code-deskphone) (2★, MIT) | 실제 아날로그 전화기로 Claude Code 세션에 전화해 프롬프트를 말하고, 답을 전화로 들음(Asterisk + whisper.cpp + macOS TTS) | 전화기와 Asterisk 필요 |
| [Vesely/skills](https://github.com/Vesely/skills) `handsfree/`, `wispr/` (28★, 라이선스 없음) | Claude Code 스킬 모음. 핸즈프리·Wispr Flow 관련 스킬 포함 | 스킬(프롬프트) 방식이라 질문 창을 대신 답하지는 않음 |

## 음성 대화 (MCP·hook)

| 프로젝트 | 하는 일 |
|---|---|
| [mbailey/voicemode](https://github.com/mbailey/voicemode) (1,463★, MIT) | Claude Code와 자연스러운 음성 대화. MCP `converse` 도구를 모델이 부를 때 동작하고 `AskUserQuestion` 창은 건드리지 않음 |
| [johnmatthewtennant/mcp-voice-hooks](https://github.com/johnmatthewtennant/mcp-voice-hooks) (130★, 라이선스 없음) | Claude Code용 음성 입출력 MCP 서버 플러그인 |
| [paulpreibisch/AgentVibes](https://github.com/paulpreibisch/AgentVibes) (155★, Apache-2.0) | Claude Code용 TTS |
| [silouone/llm-voice-loop](https://github.com/silouone/llm-voice-loop) (4★, MIT) | Claude Code·Codex의 턴 요약을 말로 들려주고(Higgs Audio TTS) SuperWhisper로 음성 입력 |
| [msaelices/claude-code-talk-to-me](https://github.com/msaelices/claude-code-talk-to-me) (7★, MIT) | Claude Code가 막혔을 때 개발자와 말로 대화하는 플러그인 |
| [LukeSmith25/voice-cc](https://github.com/LukeSmith25/voice-cc) (1★, MIT) | 음성을 주변 장치처럼 붙여 Claude Code와 대화 |
| [jochiang/voice-mcp](https://github.com/jochiang/voice-mcp) (2★, 라이선스 없음) | 로컬 Whisper + Supertonic을 쓰는 Claude Code용 음성 MCP 서버 |
| [colings86/tts-plugin](https://github.com/colings86/tts-plugin) (0★, MIT) | TTS 플러그인 |

## 읽어 주기만

| 프로젝트 | 하는 일 |
|---|---|
| [Marviel/speak_when_done](https://github.com/Marviel/speak_when_done) (41★, 라이선스 없음) | 작업이 끝나면 말로 알림 |
| [ZeldOcarina/claude-code-voice-notifications](https://github.com/ZeldOcarina/claude-code-voice-notifications) (13★, MIT) | ElevenLabs TTS로 Claude Code 음성 알림 |
| [rachittshah/claude-voice-hooks](https://github.com/rachittshah/claude-voice-hooks) (1★, MIT) | 턴 종료·권한 요청·대기 상태를 말로 알림 |
| [j3k0/mcp-speak-when-done](https://github.com/j3k0/mcp-speak-when-done) (0★, GPL-3.0) | 응답마다 짧은 요약을 말해 주는 MCP 서버 |

## Wispr Flow 제어

| 프로젝트 | 하는 일 |
|---|---|
| Raycast 확장 `wispr-flow` | 딥링크로 받아쓰기 시작·종료 |
| [pranjalv123/wispr-toggle](https://github.com/pranjalv123/wispr-toggle) (0★) | 명령줄에서 Wispr Flow 핸즈프리 모드 토글(마우스 버튼에 연결) |
| [rsktaker/wispr-voice-shortcuts](https://github.com/rsktaker/wispr-voice-shortcuts) (0★, MIT) | Wispr Flow 기반 음성 단축키 두 개(구글 검색, cmux의 Claude Code 프롬프트) |
| [peteallport/CodexMicroWisprBridge](https://github.com/peteallport/CodexMicroWisprBridge) (1★, MIT) | Codex Micro와 Wispr Flow를 잇는 macOS 브리지 |

## 앱에 내장된 기능

- Claude Code `/voice`: 프롬프트 입력을 음성으로 받아쓰기. 질문 창에 자동으로 답하지는 않음
- ChatGPT의 음성 모드·받아쓰기: 대화용이며 Codex의 질문 카드에 자동으로 답하지 않음
