# Usagi accounts: point new claude/codex runs at the account selected in the menu bar.
# Source it from ~/.zshrc (or ~/.bashrc). Reads one small file per prompt, no subprocess.
# Agent Kit users already get this from Agent Kit's own hook; both read the same state.

# $1 state folder, $2 claude|codex, $3 variable, $4 its value, $5 account set last time, $6 tracking variable
_usagi_account_apply() {
  local file="$1/account-$2" name=default value
  [[ -r $file ]] || file="$1/account"
  [[ -r $file ]] && read -r name < "$file"
  name=${name//[!abcdefghijklmnopqrstuvwxyz0123456789-]/}
  [[ -n $name && $name != default && -d "$HOME/.$2-$name" ]] || name=default
  [[ $name == "$5" ]] && return 0
  if [[ $name != default ]]; then
    export "$3=$HOME/.$2-$name"
  else
    # Only undo a value this hook set, here or in a parent shell (tmux, IDE): exactly ~/.<cli>-<name>,
    # and without a tracking variable (set before it existed) only a profile Usagi or Agent Kit made.
    value=${4#"$HOME/.$2-"}
    if [[ $value != "$4" && ${#value} -le 31 && $value == [abcdefghijklmnopqrstuvwxyz0123456789]* &&
          $value != *[!abcdefghijklmnopqrstuvwxyz0123456789-]* ]] &&
       [[ -n $5 || -e $4/.usagi-profile || -e $4/.agentkit-profile ]]; then
      unset "$3"
    fi
  fi
  # Exported, so child shells know what was set.
  export "$6=$name"
}

_usagi_account_precmd() {
  local state="$HOME/.config/iterm2/agentkit/state"
  [[ -d $HOME/.config/iterm2/agentkit ]] || state="$HOME/.config/usagi/state"
  _usagi_account_apply "$state" claude CLAUDE_CONFIG_DIR "${CLAUDE_CONFIG_DIR-}" \
    "${_USAGI_CLAUDE_ACCOUNT-}" _USAGI_CLAUDE_ACCOUNT
  _usagi_account_apply "$state" codex CODEX_HOME "${CODEX_HOME-}" \
    "${_USAGI_CODEX_ACCOUNT-}" _USAGI_CODEX_ACCOUNT
}

if [[ -n ${ZSH_VERSION-} ]]; then
  autoload -Uz add-zsh-hook
  add-zsh-hook precmd _usagi_account_precmd
else
  case ${PROMPT_COMMAND-} in
    *_usagi_account_precmd*) ;;
    *) PROMPT_COMMAND=${PROMPT_COMMAND:+$PROMPT_COMMAND$'\n'}_usagi_account_precmd ;;
  esac
fi
_usagi_account_precmd
