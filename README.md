# VoiceQuestion

AI 에이전트가 질문(AskUserQuestion)을 띄우면 **질문을 소리로 읽어 주고 → Wispr Flow 받아쓰기를 자동으로 켜고 → 말이 끝나면 자동으로 끄고 → 받아쓴 내용을 그 질문의 답으로 넣어 주는** macOS 메뉴 막대 앱입니다.

```
에이전트가 질문  →  질문 읽어 주기(TTS)  →  Wispr Flow 마이크 ON  →  말 끝 감지  →  마이크 OFF  →  답변 전달
   (hook/로그)        화면 위쪽 패널            wispr-flow://start-hands-free   마이크 레벨(VAD)    stop-hands-free    hook 응답 / 클립보드
```

- 받아쓰기는 Wispr Flow가 그대로 합니다(사전·말투 설정 유지). 이 앱은 fn 키 대신 켜고 꺼 줄 뿐입니다.
- 실패하거나 건너뛰면 항상 **원래 앱의 질문 창**으로 돌아갑니다. 답을 지어내지 않습니다.

## 요구 사항

- macOS 14 이상, Swift 툴체인(Xcode 또는 Command Line Tools)
- [Wispr Flow](https://wisprflow.ai) 실행 중 (없으면 패널만 뜨고 음성 입력은 건너뜁니다)

## 설치

```sh
git clone https://github.com/cloneisjun/voice-question.git
cd voice-question
./scripts/install.sh
```

`install.sh`가 하는 일:

1. 릴리스 빌드 → `~/Applications/VoiceQuestion.app`
2. 로그인 항목(LaunchAgent `com.cloneisjun.voicequestion`) 등록 및 실행
3. `~/.claude/settings.json`에 Claude Code hook 추가 (기존 파일은 `*.voicequestion.bak`으로 백업)

옵션: `--no-hooks`, `--no-login-item`, `--settings FILE`(다른 Claude Code 설정 파일에도 hook 추가), `--codex-hook`(실험용 Codex hook).

설치 후 **마이크 권한 창이 뜨면 '허용'** 을 눌러 주세요. 말이 끝났는지 알아내려고 입력 레벨만 재며, 녹음하거나 저장하지 않습니다. 허용하지 않아도 동작하지만 말을 마친 뒤 Enter를 눌러야 하고, 45초 동안 Enter가 없으면 그때까지 받아쓴 내용으로 진행합니다(없으면 건너뜀).

> 이미 열려 있는 Claude Code 세션에는 hook이 적용되지 않습니다. 세션을 새로 시작하세요.

편의를 위한 별칭:

```sh
alias vq="$HOME/Applications/VoiceQuestion.app/Contents/MacOS/VoiceQuestion"
```

## 테스트 시나리오

| # | 해 볼 것 | 기대 결과 |
|---|---|---|
| 1 | `vq doctor` | 앱 실행 중, Wispr Flow 실행 중, 마이크 권한 허용, Claude Code hook 설치됨 |
| 2 | 메뉴 막대 아이콘 → **테스트 질문 실행** (또는 `vq test`) 후 "파스타"라고 말하기 | 질문이 들리고, Wispr Flow가 켜지고, 말을 멈추면 약 1.6초 뒤 꺼지고, 2초 확인 뒤 "답변: 파스타" 알림 |
| 3 | 같은 질문에 "두 번째" / "2번" | 두 번째 선택지가 선택됨 |
| 4 | 같은 질문에 "건너뛰기" | 건너뜀 알림 (실제 에이전트에서는 원래 질문 창이 뜸) |
| 5 | 확인 2초 동안 Esc → 글 고치고 Enter | 고친 글이 답으로 전달됨. ⌘R은 다시 말하기 |
| 6 | `vq ask --question "배포할까요?" --option 예 --option 아니오 --json` | 답이 JSON으로 출력됨 (종료 코드 0 답변 / 2 건너뜀) |
| 7 | 새 Claude Code 세션에서 "AskUserQuestion 도구로 좋아하는 색을 물어봐 줘" | Claude Code 질문 창 대신 음성 패널이 뜨고, 말한 답으로 Claude가 이어서 진행 |
| 8 | 메뉴 → **일시 중지** 후 7번 반복 | Claude Code의 원래 질문 창이 뜸 |
| 9 | ChatGPT 데스크톱(Codex)이 질문을 띄울 때 | 질문이 들리고, 답이 클립보드에 복사되고 해당 스레드가 열림 → 질문 카드에 ⌘V |
| 10 | 소리 없이 흐름만: `vq ask --question "색?" --option 빨강 --option 파랑 --simulate "두 번째"` | 오디오 없이 "파랑" |

메뉴와 패널의 글자는 시스템 언어를 따릅니다(영어 시스템이면 메뉴는 "Ask a test question"). 읽어 주는 목소리는 질문의 언어를 따르고, 테스트 질문은 선호 언어 목록에 한국어가 있으면 한국어로 나옵니다.

### 말로 할 수 있는 것

- 선택지 이름, "첫 번째 / 2번 / 마지막", 여러 개 고르기("1번이랑 3번")
- 선택지에 없는 자유 답변 (그대로 전달)
- "건너뛰기 / 스킵 / 취소" → 원래 질문 창으로, "다시" → 다시 듣기

### 패널 단축키

Return 보내기 · Shift-Return 줄바꿈 · Esc 취소/고치기 · ⌘R 다시 말하기 · ⌘1…⌘9 선택지 고르기

## 앱별 지원

| 앱 | 질문 감지 | 답변 넣기 | 상태 |
|---|---|---|---|
| **Claude Code** (CLI·SDK·IDE) | `PreToolUse` hook (`AskUserQuestion`) | hook이 답을 돌려줌 → 질문 창 없이 바로 진행 | 지원 |
| **Claude 데스크톱 – Code 탭** | 같은 hook (`~/.claude/settings.json`) | 같음 | 동작할 것으로 보이나 미검증 |
| **Claude 데스크톱 – Chat / Cowork** | 방법 없음 | 방법 없음 | 미지원 |
| **ChatGPT 데스크톱 (Codex)** | 세션 로그 감시 (`request_user_input`) | 클립보드에 복사 + 스레드 열기 → ⌘V | 읽어 주기까지 자동, 붙여넣기는 수동 |
| **Aside** | 데몬 로그 감시 | 클립보드에 복사 → ⌘V | 읽어 주기까지 자동, 붙여넣기는 수동 |
| **Clone** | Claude Code hook (전용 설정 폴더) | hook이 답을 돌려줌 | `--settings`로 직접 추가해야 함 |

자세한 조사 내용과 한계는 [docs/app-support.md](docs/app-support.md), 무엇을 어디까지 검증했는지는 [docs/verification.md](docs/verification.md), 비슷한 오픈 소스는 [docs/similar-projects.md](docs/similar-projects.md)에 있습니다.

## 설정

`~/Library/Application Support/VoiceQuestion/config.json` (메뉴 → **설정 파일 열기**). 모든 키는 생략할 수 있고, 저장하면 다음 질문부터 적용됩니다.

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

| 키 | 기본값 | 설명 |
|---|---|---|
| `enabled` | `true` | 끄면 hook이 아무것도 하지 않음 (메뉴의 일시 중지와 같음) |
| `micStart` | `auto` | `auto`: 이어폰이면 질문과 동시에, 스피커면 질문이 끝난 뒤 마이크 ON. `immediately` / `afterSpeech`로 고정 가능 |
| `speakQuestions` | `true` | 끄면 소리 없이 패널과 마이크만 |
| `speakOptions`, `speakOptionDescriptions` | `true`, `false` | 선택지와 그 설명도 읽기 |
| `speechRate`, `speechVolume` | `1.0` | 읽는 속도 배수, 음량(0…1) |
| `voices` | `{}` | 언어별 목소리 지정, 예: `{"ko": "com.apple.voice.premium.ko-KR.Yuna"}` |
| `autoSendDelaySeconds` | `2.0` | 받아쓴 답을 보내기 전 확인 시간. `0`이면 바로 보냄 |
| `retriesOnEmpty` | `1` | 아무것도 인식되지 않았을 때 다시 듣는 횟수 |
| `skipWhenMicBusy` | `true` | 통화·녹음 등 다른 앱이 마이크를 쓰는 중이면 건너뜀 |
| `focus` | `onAnswer` | `onAnswer`: 답이 도착하기 직전에만 패널이 키보드를 가져감. `immediately`: 질문이 뜨자마자 |
| `panelActivation` | `nonactivating` | 받아쓴 글이 패널에 들어오지 않으면 `activate` |
| `vad.endSilenceSeconds` | `1.6` | 이만큼 조용하면 "답변 끝" |
| `vad.noSpeechTimeoutSeconds` | `12` | 이만큼 아무 말이 없으면 건너뜀 |
| `vad.maxAnswerSeconds` | `90` | 답변 최대 길이 |
| `vad.enabled`, `vad.device`, `vad.speechThresholdDb`, `vad.noiseMarginDb` | `true`, `auto`, 자동, `10` | 말 끝 감지 세부 조정 (`vq miccheck`로 레벨 확인) |
| `wispr.transcriptTimeoutSeconds` | `12` | 마이크를 끈 뒤 받아쓴 글을 기다리는 시간 |
| `codex.deliver` | `clipboard` | `clipboard` / `paste`(⌘V·Return까지 대신 누름, 실험용, 손쉬운 사용 권한 필요) / `none`(읽어 주기만) |
| `aside.deliver` | `clipboard` | `clipboard` / `resume`·`steer`(`aside` CLI로 전달, 실험용) / `none` |

환경 변수: `VQ_DISABLE=1`(hook 끄기), `VQ_SIMULATE_TRANSCRIPT=글`(오디오 없이 이 글로 답), `VQ_LOG_TRANSCRIPTS=1`(로그에 받아쓴 글 남기기), `VQ_SOCKET` / `VQ_CONFIG` / `VQ_LOG`(테스트용 별도 인스턴스).

## 문제 해결

- **상태 확인**: `vq doctor`, `vq status`, 로그는 `~/Library/Logs/VoiceQuestion/voicequestion.log` (메뉴 → 로그 열기)
- **다시 빌드했더니 마이크 권한을 또 묻는다**: 인증서 없이 서명(ad hoc)하기 때문입니다. 창이 안 뜨면 `tccutil reset Microphone com.cloneisjun.VoiceQuestion` 후 메뉴 → 마이크 권한 요청. 서명 인증서가 있으면 `CODESIGN_IDENTITY="Apple Development: …" ./scripts/install.sh`
- **말이 끝나기 전에 끊긴다 / 너무 늦게 끊긴다**: `vad.endSilenceSeconds`를 조정
- **주변이 시끄러워 말 끝을 못 잡는다**: `vq miccheck`로 레벨을 보고 `vad.speechThresholdDb`를 고정하거나, 말을 마치고 Enter
- **받아쓴 글이 패널이 아니라 쓰던 앱에 들어간다**: `"panelActivation": "activate"` 또는 `"focus": "immediately"`
- **스피커로 들을 때 질문 소리가 받아쓰기에 섞인다**: 기본값(`micStart: auto`)이면 스피커에서는 질문이 끝난 뒤 마이크를 켭니다. `immediately`로 바꿨다면 되돌리세요
- **Wispr Flow가 꺼져 있다**: 패널만 뜨고 45초 뒤 건너뜁니다(원래 질문 창 사용)
- **Claude Code에서 아무 일도 안 일어난다**: 세션을 새로 시작했는지, `vq hooks status`, 앱이 실행 중인지 확인. 앱이 꺼져 있으면 hook은 조용히 빠지고 원래 질문 창이 뜹니다

## 개인정보

- 마이크: 입력 레벨(dB)만 계산합니다. 오디오를 녹음·저장·전송하지 않습니다. 받아쓰기는 Wispr Flow가 합니다.
- Wispr Flow 기록(`flow.sqlite`)은 붙여넣기가 패널에 닿지 않았을 때 방금 한 받아쓰기 한 건을 읽기 전용으로 조회합니다.
- 로그에는 기본적으로 받아쓴 글이 남지 않습니다(글자 수만).
- 네트워크 통신이 없습니다. 앱과 hook은 로컬 Unix 소켓으로만 이야기합니다.

## 제거

```sh
./scripts/uninstall.sh          # 앱, 로그인 항목, hook 제거
./scripts/uninstall.sh --purge  # 설정·로그·마이크 권한까지
```

## 개발

```sh
./scripts/test.sh    # 단위 테스트 (VQCore)
./scripts/build.sh   # build/VoiceQuestion.app
```

```
Sources/VQCore/         AppKit 없는 로직: 모델, IPC, 답변 해석, 말 끝 감지, hook·로그 파서
Sources/VoiceQuestion/  메뉴 막대 앱 + CLI: 패널, 세션 상태 기계, TTS, Wispr 제어, 로그 감시, 전달
Tests/VQCoreTests/      단위 테스트
scripts/                build / install / uninstall / test
```

하나의 실행 파일이 메뉴 막대 앱이자 CLI입니다. hook(`VoiceQuestion hook claude`)은 실행 중인 앱에 Unix 소켓으로 질문을 넘기고 답을 기다렸다가 Claude Code가 이해하는 JSON으로 출력합니다. 앱이 없거나 건너뛰면 아무것도 출력하지 않고 종료해 에이전트가 자기 질문 창을 띄우게 합니다.
