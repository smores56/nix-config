{
  pkgs,
  specialArgs,
  isLinux,
  displayManager,
  ...
}:
let
  username = specialArgs.username or "smores";
  homeDirectory = specialArgs.homeDirectory or "/home/${username}";

  wallpaper = specialArgs.wallpaper or ../wallpapers/angled-waves.png;
  terminalFontSize = specialArgs.terminalFontSize or 12;
  stylixBase =
    if builtins.hasAttr "colorscheme" specialArgs then
      {
        base16Scheme = "${pkgs.base16-schemes}/share/themes/${specialArgs.colorscheme}.yaml";
      }
    else
      { };
in
{
  home = {
    stateVersion = "25.05";
    packages = [ pkgs.home-manager ];
    username = username;
    homeDirectory = homeDirectory;
  };

  targets.genericLinux.enable = isLinux;
  xdg =
    if isLinux then
      {
        enable = true;
        mime.enable = true;
        systemDirs.data = [ "${homeDirectory}/.nix-profile/share/applications" ];
      }
    else
      { };

  stylix = stylixBase // {
    enable = displayManager != null;
    enableReleaseChecks = false;
    image = wallpaper;
    autoEnable = false;
    polarity = specialArgs.polarity or "either";
    opacity.terminal = 0.8;

    cursor = {
      package = pkgs.bibata-cursors;
      name = "Bibata-Modern-Classic";
      size = 16;
    };

    fonts = {
      sizes = {
        desktop = 14;
        terminal = terminalFontSize;
      };
      sansSerif = {
        name = "Open Sans Bold";
        package = pkgs.open-sans;
      };
      monospace = {
        name = if displayManager == "osx" then "CaskaydiaCove NF" else "CaskaydiaCove NF SemiBold";
        package = pkgs.nerd-fonts.caskaydia-cove;
      };
    };

    targets.gnome.enable = displayManager == "pop-os";
  };

  home.sessionVariables = {
    OLLAMA_HOST = "http://smortress:11434";
    OLLAMA_API_BASE = "http://smortress:11434";

    OPENAI_API_KEY = "";
    OPENAI_BASE_URL = "http://smortress:11434/v1";
    OPENAI_MODEL = "cnshenyang/qwen3-nothink:14b";
  };

  imports = [
    ./terminal
  ]
  ++ (if displayManager == "osx" then [ ./osx ] else [ ])
  ++ (if displayManager == "pop-os" then [ ./gui ] else [ ]);
}
