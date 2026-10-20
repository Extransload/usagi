# Usagi accounts: point new claude/codex runs at the account selected in the menu bar.
# Source it from ~/.zshrc. Reads one small file per prompt, no subprocess.
# Agent Kit users already get this from Agent Kit's own hook; both read the same state.
_usagi_account_precmd() {
  local state="$HOME/.config/iterm2/agentkit/state" provider file name previous variable folder
  [[ -d $HOME/.config/iterm2/agentkit ]] || state="$HOME/.config/usagi/state"
  for provider in claude codex; do
    file="$state/account-$provider"
    [[ -r $file ]] || file="$state/account"
    name=default
    [[ -r $file ]] && name="$(<$file)"
    name="${name//[^a-z0-9-]/}"
    [[ -z $name ]] && name=default
    if [[ $provider == claude ]]; then
      previous="${_USAGI_CLAUDE_ACCOUNT-}"
      variable=CLAUDE_CONFIG_DIR
      folder="$HOME/.claude-$name"
    else
      previous="${_USAGI_CODEX_ACCOUNT-}"
      variable=CODEX_HOME
      folder="$HOME/.codex-$name"
    fi
    [[ $name == $previous ]] && continue
    if [[ $name == default || ! -d $folder ]]; then
      # Only undo an export made by this hook.
      [[ -n $previous && $previous != default ]] && unset "$variable"
      name=default
    else
      export "$variable=$folder"
    fi
    if [[ $provider == claude ]]; then
      typeset -g _USAGI_CLAUDE_ACCOUNT=$name
    else
      typeset -g _USAGI_CODEX_ACCOUNT=$name
    fi
  done
}
autoload -Uz add-zsh-hook
add-zsh-hook precmd _usagi_account_precmd
_usagi_account_precmd
