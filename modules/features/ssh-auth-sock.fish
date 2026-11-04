# Only an outer login with a pty publishes: `sm` runs with -t, while rsync,
# scp and git connections have no pty and would repoint the alias at a socket
# that dies with them. OpenSSH >= 10.1 forwards under ~/.ssh/agent.
if set -q SSH_AUTH_SOCK; and set -q SSH_TTY; and begin
        string match -q -- '/tmp/ssh-*/agent.*' $SSH_AUTH_SOCK
        or string match -q -- "$HOME/.ssh/agent/*" $SSH_AUTH_SOCK
    end
    if not set -q XDG_RUNTIME_DIR
        set -gx XDG_RUNTIME_DIR /run/user/(id -u)
    end
    ln -sfn $SSH_AUTH_SOCK $XDG_RUNTIME_DIR/ssh-agent.sock
    set -gx SSH_AUTH_SOCK $XDG_RUNTIME_DIR/ssh-agent.sock
end
