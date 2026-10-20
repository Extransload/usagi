# Usagi

A macOS menu bar meter for Claude Code and Codex usage limits, per account. The UI is in Korean.

macOS 메뉴바에서 Claude Code와 Codex의 사용량 한도(5시간·주간 등)와 초기화 시각을 계정별로 봅니다.
계정을 카드로 여러 개 추가하고, 새 터미널에서 쓸 계정을 고를 수 있습니다.
이름은 일본어로 토끼(うさぎ)이고, usage와 발음이 비슷해서 붙였습니다.

<img src="docs/screenshot.png" width="380" alt="Usagi 팝오버: Claude와 Codex 카드에 5시간·주간 사용률과 초기화까지 남은 시간이 표시된 화면">

## 설치

```sh
brew install --cask extransload/tap/usagi
open -a Usagi
```

- 메뉴바에 토끼 아이콘이나 사용률이 나타납니다. 누르면 계정 카드가 열립니다.
- 로그인할 때 자동으로 켜려면 **시스템 설정 > 일반 > 로그인 항목**에 Usagi를 추가하세요.
- Usagi는 Apple 개발자 서명·공증을 받지 않은 앱입니다. 바로 열 수 있도록 Homebrew 설치 과정에서 macOS 격리 표시를 지웁니다. Apple 확인 절차를 거치지 않는다는 뜻이니, 이 저장소를 믿을 때만 설치하세요.

업데이트와 삭제:

```sh
brew upgrade --cask usagi
brew uninstall --cask usagi          # 앱만 삭제
brew uninstall --zap --cask usagi    # 카드 목록·로그인 상태(~/.config/usagi)까지 삭제
```

## 필요한 것

| 항목 | 내용 |
|---|---|
| macOS | 14 Sonoma 이상 |
| CLI | [Claude Code](https://docs.anthropic.com/en/docs/claude-code)(`claude`)나 [Codex CLI](https://github.com/openai/codex)(`codex`). 하나만 있어도 됩니다 |
| Python | `/usr/bin/python3` (Xcode Command Line Tools에 들어 있습니다. Homebrew를 쓰고 있다면 이미 설치돼 있습니다) |
| 브라우저 | 로그인 창은 Google Chrome이 있으면 Chrome, 없으면 기본 브라우저로 엽니다 |

CLI는 `PATH`, `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.npm-global/bin`, `~/.bun/bin`, `~/.volta/bin`, `~/.nvm/versions/node/*/bin` 순서로 찾습니다.

## 사용법

- 처음 실행하면 이미 로그인된 CLI 계정(`default`)이 카드로 나옵니다.
- **＋**에서 Claude나 Codex를 누르면 계정 카드가 추가됩니다. 숨긴 기존 계정이 있으면 다시 보여 주고, 없으면 `account-2` 같은 새 프로필(`~/.claude-account-2`, `~/.codex-account-2`)을 만듭니다.
- **→**(로그인)은 공식 CLI 로그인을 브라우저로 엽니다. 실패하면 카드에 이유가 표시됩니다.
- 한 서비스에 계정이 여러 개면 카드 오른쪽 위 **‹ ›** 나 트랙패드 좌우 스와이프로 넘겨 봅니다. `default`가 첫 장이고, 지금 고른 계정에는 `활성` 표시가 붙습니다.
- **✓**는 새 터미널에서 쓸 계정을 고릅니다. 이 기능을 쓰려면 `~/.zshrc`에 아래 줄을 추가하세요. 새로 여는 `claude`·`codex`부터 적용되고, 실행 중인 세션은 바뀌지 않습니다.

  ```sh
  for usagi in /Applications ~/Applications; do [[ -r $usagi/Usagi.app/Contents/Resources/usagi.zsh ]] && { source $usagi/Usagi.app/Contents/Resources/usagi.zsh; break; }; done
  ```

- **휴지통**은 카드만 숨깁니다. CLI 로그아웃이나 프로필 폴더 삭제는 하지 않습니다.

## 무엇을 읽나요

- **Claude**: Claude Code가 `~/.claude.json`(추가 계정은 `~/.claude-<이름>/.claude.json`)에 저장하는 사용량 캐시에서 퍼센트와 초기화 시각만 읽습니다. 서비스를 쓴 직후에는 갱신이 늦을 수 있습니다.
- **Codex**: Codex CLI의 공식 app-server(`codex app-server`)에 계정 정보와 한도를 묻습니다. 한도 이름은 Codex가 알려 주는 기간으로 정합니다(Team: 5시간·주간, Free: 30일 등).
- 인증 토큰은 읽거나 복사하지 않습니다. 로그인은 `claude auth login`과 Codex app-server의 공식 로그인을 그대로 씁니다.
- Usagi가 저장하는 건 카드 목록(`~/.config/usagi/cards.json`), 진행 중인 로그인 표시, 고른 계정 이름뿐입니다.
- 같은 계정이면 Claude 앱·웹과 Claude Code는 한도를 공유합니다. Codex 한도도 같은 ChatGPT 계정의 다른 Codex 사용과 공유될 수 있습니다.

[Agent Kit](#agent-kit-사용자)과 같은 프로필 규칙을 씁니다. Agent Kit이 설치돼 있으면 상태 폴더를 같이 씁니다.

## 테스트한 환경

2026-10-20에 개발자 Mac 한 대에서 확인한 내용입니다.

| 항목 | 버전 |
|---|---|
| macOS | 27.0.1 (26A434), Apple Silicon |
| Claude Code | 2.1.304 |
| Codex CLI | 0.163.0 |
| Python | 3.9.6 (`/usr/bin/python3`), 테스트는 3.11.9에서도 실행 |
| Swift | 6.4 |
| Homebrew | 7.0.9 |

확인한 것:

- 설치 후 메뉴바 표시와 팝오버, 카드 스크롤, 서비스별 계정 넘기기
- 사용량 표시: Claude Max 20x(5시간·주간·모델별 주간), Codex Team(5시간·주간), Codex Free(30일)
- Codex 추가 계정 로그인(Chrome)과 로그인 직후 사용량 표시
- Finder에서 연 것과 같은 짧은 `PATH`에서 CLI 찾기와 사용량 조회
- Agent Kit이 없는 환경(빈 홈 폴더로 흉내): 오류 없이 시작, 프로필 추가, 계정 선택, `usagi.zsh`가 `CODEX_HOME`을 바꾸는 것
- 자동 테스트 29개

확인하지 못한 것:

- Intel Mac(유니버설 빌드는 했지만 실행해 보지 않았습니다)
- macOS 14·15·26에서 실제 실행
- Chrome이 없는 Mac의 로그인(기본 브라우저로 여는 동작은 자동 테스트로만 확인)
- 개발자 Mac이 아닌 곳에서의 계정 선택(✓) 실사용

문제가 있으면 [이슈](https://github.com/Extransload/usagi/issues)로 알려 주세요.

## Agent Kit 사용자

Agent Kit(`~/.config/iterm2/agentkit`)이 설치돼 있으면 Usagi는 Agent Kit의 상태 폴더와 프로필 표식(`.agentkit-profile`)을 같이 씁니다. Agent Kit의 셸 훅이 계정 선택을 이미 처리하므로 `usagi.zsh`를 따로 넣을 필요가 없습니다.

## 소스에서 설치

```sh
git clone https://github.com/Extransload/usagi.git
cd usagi
./install.sh
```

`~/Applications/Usagi.app`에 설치하고, 로그인할 때 자동으로 켜지도록 LaunchAgent를 등록합니다.

## 개발

```sh
./build.sh                                  # build/Usagi.app (arm64 + x86_64)
python3 -m unittest discover -s tests
./make-icon.sh                              # assets의 SVG를 고쳤을 때만, Google Chrome 필요
```

## 라이선스

[MIT](LICENSE)

Claude는 Anthropic의, Codex와 ChatGPT는 OpenAI의 상표입니다. Usagi는 두 회사와 관련이 없는 비공식 앱입니다.
