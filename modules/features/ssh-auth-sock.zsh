# Only an outer login with a pty publishes: `sm` runs with -t, while rsync,
# scp and git connections have no pty and would repoint the alias at a socket
# that dies with them. OpenSSH >= 10.1 forwards under ~/.ssh/agent.
if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -n "${SSH_TTY:-}" ] &&
  [[ $SSH_AUTH_SOCK == /tmp/ssh-*/agent.* || $SSH_AUTH_SOCK == "$HOME"/.ssh/agent/* ]]; then
  : "${XDG_RUNTIME_DIR:=/run/user/$(id -u)}"
  export XDG_RUNTIME_DIR
  ln -sfn "$SSH_AUTH_SOCK" "$XDG_RUNTIME_DIR/ssh-agent.sock"
  export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/ssh-agent.sock"
fi
