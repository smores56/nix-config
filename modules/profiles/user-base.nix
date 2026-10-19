# Shell, editor, git, ssh, and vault-backed identity.
{
  home = [
    ../features/shell.nix
    ../features/editor.nix
    ../features/zellij.nix
    ../features/git.nix
    ../features/ssh.nix
    ../features/ssh-keys.nix
    ../features/proton-pass.nix
    ../features/cloudflared.nix
    ../features/theme.nix
  ];
  nixos = [ ];
}
