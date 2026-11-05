# The work Mac's Homebrew casks, as a Brewfile that `just brew-bundle` applies on request. It only
# ever adds: no `cleanup`, so the employer's own brew packages stay untouched.
{
  xdg.configFile."homebrew/Brewfile".text = ''
    tap "macos-fuse-t/cask"
    tap "nikitabobko/tap"

    # kitty and aerospace come from brew: their nix builds carry a signature launchd rejects, and
    # nix app wrappers hide the real binary from LaunchServices.
    cask "kitty"
    cask "nikitabobko/tap/aerospace"
    # Brave is the browser on both laptops; the cask keeps the LaunchServices
    # registration that `open -b com.brave.Browser` depends on.
    cask "brave-browser"

    # vault mounts through fuse-t.
    cask "macos-fuse-t/cask/fuse-t"
    cask "tailscale-app"
    cask "docker-desktop"

    cask "caffeine"
    cask "gitify"
    cask "nvidia-geforce-now"
    cask "steam"
  '';
}
