# 앱별 질문 감지와 답변 전달

2026-11-17, 이 Mac에 설치된 버전 기준으로 조사한 내용입니다. 앱이 업데이트되면 달라질 수 있습니다.

## 요약

| 앱 | 질문 도구 | 감지 | 답변 전달 | 한계 |
|---|---|---|---|---|
| Claude Code (CLI·SDK·IDE 확장) | `AskUserQuestion` | `PreToolUse` hook | hook 응답의 `updatedInput.answers` | 없음. 공식 hook 계약 |
| Claude 데스크톱 – Code 탭 | `AskUserQuestion` | 같은 hook | 같음 | 실행해서 확인하지 못함 |
| Claude 데스크톱 – Chat 탭 | (선택지 UI) | 없음 | 없음 | hook이 없고 화면 읽기 외에는 방법이 없음 |
| Claude 데스크톱 – Cowork | `AskUserQuestion` | 없음 | 없음 | 격리된 VM 안에서 돌아 이 Mac의 hook이 실행되지 않음 |
| ChatGPT 데스크톱 (Codex) | `request_user_input`, `request_user_input_async` | 세션 로그(rollout) 감시 | 클립보드 + 스레드 열기 | 답을 넣는 공개 API가 없음 |
| Aside | 자체 질문 도구 | 데몬 로그 감시 | 클립보드 | 답을 넣는 공개 API가 없음 |
| Clone | `AskUserQuestion` (Claude Code 내장) | `PreToolUse` hook | `updatedInput.answers` | 전용 설정 폴더를 직접 지정해야 함 |

## Claude Code

- `~/.claude/settings.json`의 `hooks.PreToolUse`에 `matcher: "AskUserQuestion"` 항목을 추가합니다(`VoiceQuestion hooks install`). 제한 시간은 900초입니다.
- hook은 표준 입력으로 `tool_input.questions`를 받고, 답을 얻으면 다음을 출력합니다.

  ```json
  {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow",
    "updatedInput": {"questions": [...], "answers": {"<질문 문장>": "<답>"}}}}
  ```

  Claude Code는 이 답을 도구 결과로 받아 질문 창을 띄우지 않고 진행합니다.
- 아무것도 출력하지 않고 종료 코드 0으로 끝내면 평소처럼 Claude Code의 질문 창이 뜹니다. 앱이 꺼져 있을 때, 일시 중지했을 때, "건너뛰기"라고 말했을 때, 아무 말도 안 했을 때가 모두 이 경로입니다. hook이 앱을 대신 실행하지는 않습니다.
- 여러 질문이 한 번에 오면 차례로 읽고 답을 받습니다. 여러 개 선택(`multiSelect`)은 선택지 이름을 쉼표로 이어 전달합니다.

## Claude 데스크톱

- **Code 탭**은 내장 Claude Code를 실행하며 `~/.claude/settings.json`의 hook을 읽는 것으로 보입니다(앱 코드를 읽어서 확인한 것이고, 실제로 질문을 띄워 확인하지는 못했습니다).
- **Chat 탭**에는 hook이 없습니다. 화면을 읽어(손쉬운 사용 API) 질문을 찾는 방법은 깨지기 쉬워 넣지 않았습니다.
- **Cowork**은 격리된 VM에서 에이전트를 돌리기 때문에 이 Mac에 설치한 hook이 실행되지 않습니다.

## ChatGPT 데스크톱 (Codex)

- 앱은 `/Applications/ChatGPT.app` (번들 ID `com.openai.codex`)이고, 세션 기록을 `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`에 실시간으로 씁니다.
- VoiceQuestion은 이 폴더를 감시하다가 `request_user_input` / `request_user_input_async` 호출이 기록되면 질문을 읽어 줍니다. 같은 호출의 결과가 먼저 기록되면(앱에서 직접 답한 경우) 음성 흐름을 멈춥니다.
- Codex에는 밖에서 답을 넣는 방법이 없습니다. 그래서 기본 동작은 **답을 클립보드에 복사하고 `codex://threads/<id>`로 해당 스레드를 여는 것**까지이고, 질문 카드에 붙여 넣는 것(⌘V)은 직접 합니다.
- 실험용 선택 사항 두 가지:
  - `"codex": {"deliver": "paste"}`: ChatGPT가 맨 앞에 있으면 선택지 숫자 키 또는 ⌘V와 Return을 대신 누릅니다. 손쉬운 사용 권한이 필요하고, 질문 카드의 키 동작에 의존하므로 앱 업데이트에 깨질 수 있습니다.
  - `VoiceQuestion hooks install --codex`: `~/.codex/hooks.json`에 `PreToolUse` hook을 추가합니다(기존 hook은 그대로 둡니다). Codex hook은 답을 돌려줄 수 없어서, 도구 호출을 거절하고 그 사유에 답을 적어 모델에게 전달하는 방식입니다. ChatGPT 앱에서 이 hook을 **신뢰(Trust)** 해야 실행되며, 이 도구들에 `PreToolUse`가 실제로 불리는지는 확인하지 못했습니다.

## Aside

- 번들 ID `at.studio.AsideBrowser`, CLI는 `aside`. 데몬 로그 `~/.aside/logs/daemon-YYYY-MM-DD.log`에 질문 요청이 기록됩니다.
- VoiceQuestion은 이 로그를 감시해 질문을 읽어 주고, 답은 클립보드에 복사한 뒤 Aside를 앞으로 가져옵니다. 질문에 붙여 넣는 것(⌘V)은 직접 합니다.
- 실험용: `"aside": {"deliver": "steer"}`는 `aside session steer`로 진행 중인 세션에 답을 메시지로 보내고, `"resume"`은 세션을 멈췄다가(`session stop`) 답과 함께 다시 이어 갑니다(`session resume`). 둘 다 질문 카드에 답하는 것이 아니라 대화에 덧붙이는 방식이어서 질문 카드가 화면에 남을 수 있고, 실패하면 클립보드 방식으로 돌아갑니다.

## Clone

Clone은 Claude Code를 자체 설정 폴더(`CLAUDE_CONFIG_DIR`)로 실행합니다. 그 폴더의 `settings.json`을 지정하면 같은 hook이 동작합니다.

```sh
./scripts/install.sh --settings "<Clone의 .claude 폴더>/settings.json"
```

## Wispr Flow 제어

- 켜기 / 끄기: `wispr-flow://start-hands-free`, `wispr-flow://stop-hands-free` 딥링크(앱을 앞으로 가져오지 않고 엽니다). fn 키를 누른 것과 같은 받아쓰기 세션이 시작됩니다.
- Wispr Flow는 받아쓴 글을 **현재 키보드 포커스에 붙여 넣기(⌘V)** 로 전달합니다. 그래서 답이 도착하기 직전에 질문 패널이 키보드 포커스를 가져가 붙여넣기를 가로채고(쓰던 앱은 맨 앞에 그대로 둡니다), 끝나면 돌려줍니다.
- 붙여넣기가 패널에 닿지 않은 경우를 대비해 Wispr Flow의 로컬 기록(`flow.sqlite`의 `History`)에서 방금 받아쓰기를 읽어 옵니다. Wispr Flow는 붙여넣기를 마친 뒤에 최종 상태를 기록하므로, 상태가 없거나 `processing`인 행은 진행 중으로 봅니다.
- 말 끝 감지는 Wispr Flow가 쓰는 마이크의 입력 레벨을 재서 합니다(주변 소음에 맞춰 기준을 잡고, 기본 1.6초 조용하면 끝).
