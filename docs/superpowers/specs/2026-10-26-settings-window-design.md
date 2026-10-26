# Usagi 설정창 (사이드바) 설계

작성일 2026-10-26. 표기: **(사용자)** 사용자가 정한 것 · **(결정)** 대화 중 제가 정하고 알린 것 · **(빌더)** 만드는 사람에게 맡기는 것.

## 1. 왜 만드는가

Usagi의 메뉴바는 CodexBar처럼 자유롭게 꾸밀 수 있어야 한다 **(사용자)**. 1단계로 서비스별 색상(hex)과 메뉴바 표시 켜기/끄기를 만들었고(아래 2번), 이번 단계에서는 설정창을 CodexBar처럼 **사이드바가 있는 창**으로 바꾸고 기능을 넓힌다 **(사용자)**. 사이드바에는 일반 페이지(General, Menu Bar, Notifications, About)와 **서비스별 페이지(Claude, Codex)**가 있다 **(사용자)**. 넣을 기능은 CodexBar에서 Usagi에 필요한 것을 골라 오되 **(사용자)**, 사용자가 확정한 시안(5·6번)을 따른다.

성공 기준: 사용자가 메뉴바와 Usagi 동작을 설정창 한 곳에서 바꿀 수 있고, CodexBar 설정창과 비슷한 수준으로 정돈되어 보인다.

## 2. 이미 있는 것 (커밋 전, 작업 트리에 있음)

- `Sources/Glyphs.swift`: CodexBar의 Claude/OpenAI 로고 경로(MIT 고지 포함). `SVGPath`(Logic.swift)로 해석해 직접 그린다.
- `Sources/Logic.swift`: `RGB`(hex 해석, 대비), `MenuBarStyle`(기본색 Claude `#CC7C5E` / Codex `#49A3B0`, 대비 2:1 판정, 흑백 전환 규칙, 경고 문구), `MenuBar.items(_:hidden:)`, `MenuBar.services`, `MenuBar.hidden(migrating:order:)`.
- `Sources/ProviderIcons.swift`: `MenuBarGlyphs`(로고 이미지, 동적 색, 메뉴바 라벨).
- `Sources/Settings.swift`: `MenuBarSettings`(UserDefaults: `menuBarColor.<provider>`, `menuBarHidden`, 옛 `menuBarServices` 이전), 사이드바 없는 단순 설정창 `SettingsWindow`.
- `Sources/main.swift`: 우클릭 메뉴 **Settings…** (⌘,), 숨은 메인 메뉴(Edit 단축키, ⌘W, ⌘Q), 메뉴 열림 추적.
- 테스트 `tests/swift/main.swift` 275개 통과. README/CHANGELOG 1.0.11 항목.

이번 작업은 이 위에 쌓는다. 단순 설정창(`SettingsWindow`, `ServiceSection`)은 사이드바 창으로 대체된다. 색상·표시 스위치의 동작은 그대로 서비스 페이지로 옮긴다.

## 3. 목표 / 비목표 / 실패 조건

**목표**
- 사이드바 설정창: Usagi 그룹(General, Menu Bar, Notifications, About)과 Services 그룹(카드 순서대로 Claude, Codex).
- 시안의 모든 항목이 실제로 동작하고 바로 반영된다(저장 버튼 없음).

**비목표 (만들지 않음)** **(사용자/결정)**
- 레이아웃 편집기(칩 끌어다 놓기), 페이스·리셋 시각·막대 같은 % 외 표시 형태 **(사용자: 앞서 "안 할래요")**.
- 색 켜기/끄기 토글 **(사용자)**.
- 계정별 색, CodexBar의 iCloud 동기화·비용 대시보드·플러그인·훅·언어/통화 **(결정)**.
- 팝오버(카드 메뉴) 화면 변경. 설정은 메뉴바와 앱 동작에만 영향을 준다 **(결정)**.

**실패 조건 (동작해도 실패)**
- 설정창에 시안에 쓰던 출처 꼬리표("지금 있음", "CodexBar", "새로")가 보인다 **(사용자: 제거 요청)**.
- 설정을 바꿨는데 메뉴바가 바로 안 바뀐다.
- 같은 알림이 반복해서 온다(재시작 후 포함).
- 빌드가 `swiftc` 직접 호출(`build.sh`, CI의 Xcode 15)에서 깨진다.

## 4. 제약

- macOS 14 이상, `build.sh`가 `/usr/bin/swiftc`를 직접 호출한다(Xcode 프로젝트 없음). 이 Mac의 최신 SDK에서는 SwiftUI `@State`가 매크로라서 플러그인 없이 컴파일되지 않는다 → **설정창은 AppKit으로 만든다 (결정)**. 외부 의존성 추가 없음.
- Swift 5 모드로 빌드하되 Swift 6 모드에서도 경고 없이 컴파일되게 유지한다(지금 상태 유지).
- Usagi는 서명 없는(ad-hoc) 앱이고, 같은 번들 ID의 앱은 하나만 실행된다.
- UI 문구는 영어(앱 전체가 영어) **(결정)**.
- 설정은 모두 `UserDefaults.standard`에 저장한다. 키는 아래 각 절에 적는다.
- 순수 로직(값 변환, 판정, 중복 방지 키 등)은 Foundation만 쓰는 `Logic.swift`에 두고 `tests/swift/main.swift`에 테스트한다(기존 관례).

## 5. 창 구조

- 우클릭 **Settings…** (⌘,)로 연다. 이미 열려 있으면 앞으로 가져온다. 팝오버가 열려 있으면 닫는다.
- 창: 제목 "Usagi Settings", 닫기 버튼, 크기 약 720×520, 크기 조절 가능(최소 크기 있음) **(결정)**. 처음 열 때 화면 가운데.
- 왼쪽 사이드바(macOS 기본 소스 리스트 모양, `NSSplitViewController`의 사이드바 항목 권장 **(빌더)**):
  - 그룹 **Usagi**: General(⚙︎), Menu Bar, Notifications, About — 각자 색 있는 작은 아이콘 **(빌더: SF Symbols 권장)**.
  - 그룹 **Services**: 카드 순서대로 서비스. 아이콘은 그 서비스의 로고를 **현재 색**으로 그린 것. 카드가 없는 서비스도 뒤에 나온다(`MenuBar.services`).
- 오른쪽: 선택한 페이지. 각 페이지는 제목 + 회색 소제목(대문자) + 둥근 상자 안 행들(macOS 시스템 설정과 비슷한 모양). 행은 왼쪽에 라벨, 오른쪽에 컨트롤. 라벨 아래 회색 한 줄 설명은 이 문서에 영어로 적힌 안내가 있는 행에만 넣는다(빌더가 짧게 다듬어도 됨). 사용자에게 보여준 시안의 한국어 메모와 출처 꼬리표는 넣지 않는다 **(사용자/결정)**.
- 컨트롤 종류 **(결정)**: 켜기/끄기는 스위치(`NSSwitch`), 2~4개 중 하나 고르기(새로고침 간격, Used/Remaining, 글자 크기)는 세그먼트 컨트롤, 그 밖의 목록(알림 문턱 두 개, Limit shown)은 팝업 버튼.
- 마지막으로 연 페이지를 기억한다(`settingsPane`) **(결정)**.
- 창을 닫으면: 색상 패널 정리, 다른 Usagi 창이 없으면 앱 비활성화(지금 구현 유지).
- 설정창이 열린 채로 카드 순서가 바뀌면 다음에 열 때 반영된다(지금 구현 유지, 입력 중 포커스 보호) **(결정)**.

## 6. 페이지별 동작

### 6.1 General

| 행 | 동작 | 저장 |
|---|---|---|
| Start at login | 켜면 `SMAppService.mainApp.register()`, 끄면 `unregister()`. 스위치는 실제 상태(`status`)를 보여준다. 승인이 필요하면(`.requiresApproval`) 아래에 "Allow Usagi in System Settings > General > Login Items" 안내와 그 화면을 여는 버튼 | 시스템이 보관(UserDefaults 없음) |
| Also Use in Apps | 우클릭 메뉴의 같은 항목과 같은 동작·같은 값. 둘 다 남긴다 **(결정)** | 기존 `alsoUseInApps` |
| Refresh while the menu is closed | 1m / 2m / 5m / 15m. 기본 5m(지금 값). 메뉴가 열려 있을 때는 지금처럼 1분. 설명: "While the menu is open, Usagi refreshes every minute." 메뉴바가 "오래됨"으로 흐려지는 기준은 `max(15분, 간격 + 5분)`으로 바꿔서, 15m을 고르면 새로고침 사이마다 흐려지는 일이 없게 한다 **(결정)** | `refreshInterval` (초) |
| Open Usagi (keyboard shortcut) | 단축키 기록 컨트롤. 누르면 어디서든 카드 메뉴(팝오버)를 열고 닫는다. 기본은 없음. 지우기 버튼 있음. ⌘⌥⌃ 중 하나 이상이 없는 단축키는 받지 않는다(⇧만 쓰면 대문자 입력을 가로채므로) **(결정)** | `openShortcut` (키 코드 + 수식키) |

- 전역 단축키는 Carbon `RegisterEventHotKey` 권장(권한 요청 없음) **(빌더)**. 이미 다른 앱이 쓰는 조합이면 등록 실패를 행 아래에 알린다.

### 6.2 Menu Bar

| 행 | 동작 | 저장 |
|---|---|---|
| (미리보기) | 페이지 위쪽에 현재 설정으로 그린 메뉴바 라벨(라이트/다크 메뉴바 배경 두 줄). 설정을 바꾸면 바로 바뀐다 | — |
| Show percentages as | Used / Remaining. Remaining이면 메뉴바 숫자를 `100 − 사용률`로 보여준다(0 아래로 안 감). 카드·알림 기준은 그대로 사용률 | `menuBarShowsRemaining` (Bool) |
| Text size | Small / Regular / Large = 글자 10 / 11(지금) / 13pt, 로고 12 / 14 / 16pt **(결정)** | `menuBarTextSize` |
| Show logos | 끄면 숫자만. 색은 숫자에 그대로 들어간다. 모두 흑백일 때(메뉴 열림 등) 서비스 구분이 안 되는 것은 감수한다 **(결정)** | `menuBarShowsLogos` (기본 true) |
| (안내) | "Turn services on or off, set their colors and the limit they show on each service's page." | — |

- VoiceOver 라벨은 Remaining일 때 "Claude 58% left"처럼 바꾼다 **(결정)**.

### 6.3 Notifications

| 행 | 동작 | 저장 |
|---|---|---|
| Warn when a limit passes | 두 개의 값(기본 80%, 95%). 각각 Off / 50 / 60 / 70 / 80 / 90 / 95 중 선택 **(결정)** | `notifyThresholds` ([Int]) |
| When a limit is used up | 사용률이 100%에 닿으면 알림 | `notifyUsedUp` (기본 true) |
| When a limit resets | 사용하던 한도가 리셋되면 알림("Claude's 5-hour limit has reset") | `notifyReset` (기본 true) |
| (안내) | 회색 안내: "Claude's numbers change only when Claude Code updates them, so an alert can come hours late." | — |

규칙:
- 대상: 서비스마다 **메뉴바에 쓰는 계정**(Active 카드, 숨겨졌으면 첫 카드)의 모든 한도(5시간, 주간, 모델별 주간, Codex의 기간별) **(결정)**. 메뉴바 표시를 끈 서비스도 알림은 온다 **(결정)**.
- **기록**: 한도마다(서비스·계정·한도 키) 마지막으로 본 `{주기(resets_at), 사용률}`을 저장한다(`notifyState`, 재시작 후에도 유지, 35일 넘게 갱신 안 된 항목은 정리) **(결정)**.
- **문턱 알림 = "넘는 순간을 봤을 때"만**: 같은 주기 안에서 지난 사용률 < 문턱 ≤ 지금 사용률이면 알린다. 다 씀은 문턱 100으로 취급한다. 한 번에 여러 문턱을 넘었으면 **가장 높은 것 하나만** 알린다(다 씀 > 95 > 80). 한 한도는 한 스냅샷에서 알림을 최대 한 번 보낸다 **(결정)**.
- **처음 보는 한도는 조용히 기록만**: 기록이 없는 한도(업데이트 후 첫 실행, 처음 보는 계정, Active 계정 전환)는 그때 값을 기록만 하고 알리지 않는다. 그래서 업데이트 직후나 계정 전환 직후에 알림이 쏟아지지 않는다. 문턱 값을 바꿔도 기록된 사용률 기준으로 "넘는 순간"만 알리므로 바꾸는 즉시 알림이 오지 않는다 **(결정)**.
- **리셋 판정 (Claude·Codex 공통)**: (가) 그 한도의 `resets_at`이 기록보다 60초 넘게 뒤로 바뀌었거나(새 주기), (나) 스냅샷이 `reset: true`를 처음 보고하면 리셋으로 본다. 기록된 사용률이 0보다 컸을 때만 리셋 알림을 보낸다. (나) 뒤에 새 주기 값이 들어오면 기록 사용률이 이미 0이라 다시 알리지 않는다. Codex는 `reset` 표시가 없으므로 (가)로만 잡힌다. 맥이 잠든 사이 리셋이 지나가도 (가)로 잡힌다. 새 주기로 넘어간 스냅샷에서 이미 문턱을 넘었으면 0에서부터 넘은 것으로 보고 문턱 알림이 우선한다 **(결정)**.
- 오래된(stale) 값으로도 알린다. 늦을 수는 있어도 틀린 값은 아니기 때문이다 **(결정)**.
- 알림은 `UNUserNotificationCenter`. 처음 켜질 때 권한을 요청한다. 거부되었거나 ad-hoc 서명 때문에 쓸 수 없으면 이 페이지 위쪽에 "Notifications are turned off for Usagi" + System Settings 열기 버튼을 보여주고 나머지 행은 비활성화한다 **(결정)**. ad-hoc 서명 앱에서 실제로 동작하는지 먼저 확인할 것 **(빌더)**.
- 알림을 누르면 카드 메뉴(팝오버)를 연다 **(결정)**.

### 6.4 About

| 행 | 동작 |
|---|---|
| Usagi 버전 | 앱 아이콘, "Usagi 1.0.x", 업데이트 상태 한 줄(Up to date · checked 4m ago / 1.0.12 is available / Couldn't check). 기존 `Updates`/`UpdateStatus` 결과를 공유한다 |
| Check for Updates | 지금 확인(`Updates.check(force: true)`). 새 버전이 있으면 버튼이 "Update to 1.0.12…"로 바뀌고, 누르면 카드 메뉴를 열어 기존 업데이트 배너에서 진행한다(업데이트 실행 경로는 하나로 유지) **(결정)** |
| Links | GitHub, Releases, Changelog(링크는 github.com/Extransload/usagi) |
| Acknowledgements | "Menu bar logos from CodexBar (MIT) · © 2026 Peter Steinberger", 누르면 CodexBar 저장소 |

### 6.5 서비스 페이지 (Claude, Codex)

제목 옆에 서비스 로고(현재 색).

**Menu bar** 상자:

| 행 | 동작 | 저장 |
|---|---|---|
| Show in menu bar | 지금 구현 그대로 | `menuBarHidden` |
| Color | hex 입력 + 색상 선택기, 지금 구현 그대로(입력 중 바로 적용, 잘못된 값은 편집이 끝나면 되돌림) | `menuBarColor.<provider>` |
| Default #RRGGBB / Reset | 지금 구현 그대로. 기본색과 같으면 저장하지 않음 | — |
| (대비 경고) | 지금 구현 그대로 | — |
| Limit shown | 메뉴바 %가 따를 한도. **Higher of 5-hour and weekly**(기본, 지금 방식: 5시간·주간 중 높은 값, 둘 다 없으면 아무 한도 중 가장 높은 값) / 그 서비스에서 지금 읽히는 각 한도(카드와 같은 이름: "5-hour", "Weekly", "30-day", "Fable weekly" …) | `menuBarLimit.<provider>` (`"auto"` 또는 한도 키) |

- 목록은 **메뉴바에 쓰는 계정**(Active 카드, 숨겨졌으면 첫 카드)이 지금 보고하는 한도로 만든다. Active 계정이 바뀌면 목록도 따라 바뀐다 **(결정)**.
- 저장된 한도가 그 계정의 지금 데이터에 없으면 목록에 "(not reported now)"를 붙여 남겨 두고, 메뉴바에는 그 서비스 숫자 자리에 "–"를 보여준다(다른 한도로 바꿔치지 않음, CodexBar와 같음) **(결정)**.
- 한도 이름 규칙은 `index.html`의 `windowLabel`과 같아야 한다(같은 규칙을 Logic.swift에 두고 테스트) **(결정)**.

**Status** 상자 (읽기 전용):
- Accounts: 카드에 있는 계정들의 이메일(로그인 안 된 계정은 "Account 2" 식, 카드와 같은 규칙), Active 계정에 "(Active)".
- "Updated 4m ago"(마지막 성공 스냅샷)와 CLI 상태 "Claude Code found" / "not found". 경로는 스냅샷에 없으므로 보여주지 않는다 **(결정: 시안의 경로 표시는 생략)**.

## 7. 메뉴바 그리기 변경 요약

`MenuBarGlyphs.label`이 받는 값: 항목들, paint, 서비스 색, **글자 크기**, **로고 표시 여부**, **Remaining 여부**. `MenuBar.items`는 서비스별 **선택 한도**를 받아 그 한도의 값을 쓴다. 나머지 규칙(흑백 전환, 대비, 숨김, 토끼)은 그대로.

## 8. 확인 방법

- `tests/swift/run.sh`: 새 순수 로직(한도 선택, 한도 이름, Remaining 변환, 문턱/리셋 알림 판정과 중복 방지, 새로고침 간격, 단축키 저장 형식)을 테스트로 먼저 쓴다.
- `python3 -m unittest discover -s tests`, `./build.sh`, `.github/verify-app.sh`, Swift 6 모드 컴파일.
- 화면 밖 렌더링으로 각 페이지(라이트/다크)와 메뉴바 라벨(크기 3종, 로고 끔, Remaining)을 이미지로 확인하고, 하네스로 컨트롤 → UserDefaults 반영을 확인(이번 1단계와 같은 방식).
- 실제 앱 실행 확인은 설치된 Usagi를 끄고 새 빌드를 띄워야 하므로 사용자에게 먼저 묻는다.
- 독립 리뷰 1회.

## 9. 문서

README(Usage의 메뉴바·설정 설명, "로그인 시 실행" 안내를 설정창 기준으로), CHANGELOG 1.0.11 항목을 이번 범위로 고친다.

## 10. 빌더에게 맡기는 것

- 사이드바와 페이지의 AppKit 구성 방식(뷰 컨트롤러 나누기, 행 공용 컴포넌트), 아이콘 선택, 정확한 여백.
- 단축키 기록 컨트롤의 구현.
- 알림 중복 방지 기록의 형식과 정리 주기.
- 파일 나누기(예: `Settings.swift`를 창/페이지/모델로 분리).
