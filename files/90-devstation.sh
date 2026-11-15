# /etc/profile.d/90-devstation.sh
#
# System-wide bash quality-of-life for this image.
#
# Loaded twice on a login shell — once from /etc/profile and again from
# /etc/bashrc — so the guard below is required, not decorative. Non-interactive
# shells (scripts, systemd units, %post) exit immediately and inherit nothing.
#
# Deliberately absent: EDITOR/VISUAL (no editor is shipped beyond vi/nano by
# default), aliases (they do not survive sudo and confuse shared shell
# snippets), and any framework or plugin manager.

[ -n "${DEVSTATION_PROFILE_LOADED:-}" ] && return 0
DEVSTATION_PROFILE_LOADED=1

case $- in
*i*) ;;
*) return 0 ;;
esac

# --- History --------------------------------------------------------------
# Large, shared between windows, appended immediately so a crash does not lose
# the session, with duplicates collapsed.
HISTSIZE=100000
HISTFILESIZE=200000
HISTCONTROL=ignoreboth:erasedups
shopt -s histappend cmdhist lithist

# --- Shell behaviour ------------------------------------------------------
# globstar: ** matches recursively, which every modern tool expects.
# direxpand: Tab-completing a directory shows the real path, not a variable.
# autocd is intentionally off: a typo should not silently change directory.
shopt -s checkwinsize globstar direxpand
PROMPT_DIRTRIM=2

# --- Completion -----------------------------------------------------------
# bash-completion is installed by the workstation group and sets itself up.
bind 'set completion-ignore-case on' 2>/dev/null
bind 'set show-all-if-ambiguous on' 2>/dev/null

# --- fzf: Ctrl-R history, Ctrl-T files, Alt-C cd --------------------------
if [ -r /usr/share/fzf/shell/key-bindings.bash ]; then
	. /usr/share/fzf/shell/key-bindings.bash
fi

# --- Directory jumping and per-project environments -----------------------
if command -v zoxide >/dev/null 2>&1; then
	eval "$(zoxide init bash)"
fi
if command -v direnv >/dev/null 2>&1; then
	eval "$(direnv hook bash)"
fi

# --- Prompt ---------------------------------------------------------------
# Written as a PROMPT_COMMAND hook rather than a static PS1 because the git
# branch can change between prompts. Fedora's own /etc/bashrc may declare
# PROMPT_COMMAND as an array (vte-profile does on Workstation), so append in a
# way that preserves whichever form is already there.
_devstation_prompt() {
	local status=$? branch
	branch=$(GIT_OPTIONAL_LOCKS=0 git rev-parse --abbrev-ref HEAD 2>/dev/null)

	PS1='\[\e[1;32m\]\u@\h\[\e[0m\] \[\e[1;34m\]\w\[\e[0m\]'
	if [ -n "$branch" ] && [ "$branch" != "HEAD" ]; then
		PS1+=" \[\e[0;33m\]($branch)\[\e[0m\]"
	fi
	if [ "$status" -ne 0 ]; then
		PS1+=" \[\e[1;31m\]$status\[\e[0m\]"
	fi
	PS1+=' \$ '
}

if [[ ${PROMPT_COMMAND@a} == *a* ]]; then
	PROMPT_COMMAND+=(_devstation_prompt)
else
	PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND; }_devstation_prompt"
fi
