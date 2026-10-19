# smoreswork: the employer's macOS laptop. Home-only (no NixOS config); its
# `system` drives the Darwin home build.
{
  system = "aarch64-darwin";
  username = "sam";
  home = true;

  user = {
    aiProfile = "work";
    brain.dir = "brain";
  };
}
