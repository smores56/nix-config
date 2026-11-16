# Parity differences that exist only while a piece is handed over to the dotfiles repo
# (`user.dotfilesOwns` on smoreswork). Keys are `<category>/<name>` as in laptop_parity.nix. laptop_parity.nix
# exempts a piece's keys only while it is listed, in both directions: a difference the handover causes needs no
# sanction, and a sanctioned difference the handover erases is not stale. Reasons are in the option's description.
{
  zsh = [
    "packages/zellij-tab-rename"
    "packages/zsh"
    "packages/nix-zsh-completions"
    "programs/zsh"
  ];
  helix = [
    "packages/helix"
    "programs/helix"
  ];
  zellij = [
    "packages/zellij"
    "programs/zellij"
  ];
  yazi = [
    "packages/yazi"
    "programs/yazi"
  ];
  lazygit = [
    "packages/lazygit"
    "programs/lazygit"
  ];
  television = [ ];
  gh = [
    "activation/migrateGhAccounts"
    "programs/gh"
  ];
  aerospace = [
    "packages/aerospace-layout"
    "programs/aerospace"
  ];
}
