{ inputs, mkPkgs, ... }:
let
  inherit (inputs)
    home-manager
    niri
    noctalia
    concord
    stylix
    sops-nix
    disko
    ;
  inherit (inputs.nixpkgs) lib;

  localOverlays = system: [
    niri.overlays.niri
    (final: prev: {
      googlesans-code = prev.stdenv.mkDerivation (finalAttrs: {
        pname = "googlesans-code";
        version = "7.000";

        src = prev.fetchFromGitHub {
          owner = "googlefonts";
          repo = "googlesans-code";
          tag = "v${finalAttrs.version}";
          hash = "sha256-XjsjBMCA1RraXhQiNq/D0mb//VnRKOWl1X4XpGzifNA=";
        };

        nativeBuildInputs = [ prev.fontc ];

        buildPhase = ''
          runHook preBuild

          mkdir -p fonts/variable
          fontc sources/GoogleSansCode.glyphspackage --flatten-components --decompose-transformed-components --output-file "fonts/variable/GoogleSansCode[MONO,wght].ttf"
          fontc sources/GoogleSansCode-Italic.glyphspackage --flatten-components --decompose-transformed-components --output-file "fonts/variable/GoogleSansCode-Italic[MONO,wght].ttf"

          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall

          mkdir -p $out/share/fonts/googlesans-code
          cp fonts/variable/* $out/share/fonts/googlesans-code/

          runHook postInstall
        '';

        meta = {
          description = "Google Sans Code font family";
          homepage = "https://github.com/googlefonts/googlesans-code";
          changelog = "https://github.com/googlefonts/googlesans-code/blob/${finalAttrs.src.tag}/CHANGELOG.md";
          license = lib.licenses.ofl;
          maintainers = with lib.maintainers; [ shiphan ];
          platforms = lib.platforms.all;
        };
      });

      concord = concord.packages.${system}.default;

      # See the nixpkgs-unstable input: rclone needs the protondrive fixes it
      # carries (1.75.1) for a trustworthy Proton mirror.
      rclone = inputs.nixpkgs-unstable.legacyPackages.${system}.rclone;

      # The pinned nixpkgs ships tuicr 0.19.1. The review bridge redirects
      # --stdout to capture the export, and 0.27 carries the editor-stdio fix
      # (#740) that keeps the TUI's editor alive in that mode.
      tuicr = inputs.nixpkgs-unstable.legacyPackages.${system}.tuicr;
    })
  ];

  pkgsForSystem =
    system:
    mkPkgs system {
      overlays = localOverlays system;
    };

  homeModules = [
    ../options.nix
    ../home.nix
    niri.homeModules.niri
    noctalia.homeModules.default
    stylix.homeModules.stylix
    sops-nix.homeManagerModules.sops
  ];

  # providers.nix injects `_module.args.aiProviders` for maki and cloudflared.
  # Pure data — safe to import into NixOS evaluations too.
  nixosModules = [
    ../options.nix
    ../features/ai/providers.nix
    sops-nix.nixosModules.sops
    # Declarative disk layouts: a host with modules/hosts/<name>/disko.nix
    # derives its fileSystems from disko.devices (see AGENTS.md).
    disko.nixosModules.disko
  ];

  # Hosts are discovered from modules/hosts/<name>/; adding a host means adding
  # a directory (meta.nix + default.nix + hardware.nix), never editing this file.
  hostsDir = ../hosts;
  hostNames = builtins.attrNames (
    lib.filterAttrs (_: type: type == "directory") (builtins.readDir hostsDir)
  );
  hostMeta =
    name:
    let
      metaPath = hostsDir + "/${name}/meta.nix";
      meta =
        if builtins.pathExists metaPath then
          import metaPath
        else
          throw "modules/hosts/${name}/ has no meta.nix (see AGENTS.md)";
      # Catch typos in the top-level keys: a misspelled `home`/`nixos` flag or
      # options section would otherwise be silently ignored.
      allowed = [
        "system"
        "username"
        "nixos"
        "home"
        "machine"
        "user"
        "homeOptions"
        "nixosOptions"
      ];
      unknown = builtins.filter (key: !(builtins.elem key allowed)) (builtins.attrNames meta);
    in
    if unknown != [ ] then
      throw "modules/hosts/${name}/meta.nix has unknown keys: ${lib.concatStringsSep ", " unknown}"
    else
      meta;

  # A host names its profiles explicitly; each profile contributes module paths
  # to the home and NixOS planes. The names also drive machine.graphical/
  # wayland/workHost and the server-profile assertion.
  hostProfiles =
    name:
    let
      path = hostsDir + "/${name}/default.nix";
      m =
        if builtins.pathExists path then
          import path
        else
          throw "modules/hosts/${name}/ has no default.nix (see AGENTS.md)";
    in
    map (p: {
      name = lib.removeSuffix ".nix" (baseNameOf (toString p));
      inherit p;
    }) m.profiles;

  profileModules =
    name: kind: lib.concatMap (profile: (import profile.p).${kind} or [ ]) (hostProfiles name);

  hostModule = args: profileNames: {
    machine = (args.machine or { }) // {
      inherit (args) username system;
      nixos = args.nixos or false;
      profiles = profileNames;
    };
    user = args.user or { };
  };

  normalize =
    m:
    m
    // {
      username = m.username or "smores";
      system = m.system or "x86_64-linux";
    };

  mkHome =
    args:
    let
      system = args.system or "x86_64-linux";
      username = args.username or "smores";
      profiles = hostProfiles args.hostname;
      profileNames = map (p: p.name) profiles;
    in
    home-manager.lib.homeManagerConfiguration {
      pkgs = pkgsForSystem system;
      extraSpecialArgs = {
        inherit inputs;
      };
      modules =
        homeModules
        ++ profileModules args.hostname "home"
        ++ [
          (hostModule args profileNames // (args.homeOptions or { }))
          {
            home.username = username;
            home.homeDirectory =
              args.homeDirectory
                or (if lib.hasSuffix "-darwin" system then "/Users/${username}" else "/home/${username}");
          }
        ];
    };

  mkNixos =
    args:
    let
      system = args.system or "x86_64-linux";
      profiles = hostProfiles args.hostname;
      profileNames = map (p: p.name) profiles;
    in
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = { inherit inputs; };
      modules = [
        { nixpkgs.overlays = localOverlays system; }
      ]
      ++ nixosModules
      ++ profileModules args.hostname "nixos"
      ++ lib.optionals (builtins.elem "linux-desktop" profileNames) [ niri.nixosModules.niri ]
      # hardware.nix is optional so a host can be authored (meta.nix +
      # disko.nix) before nixos-anywhere generates it during the install; the
      # guard keeps the flake evaluable in that window (see AGENTS.md). Warn
      # loudly because a missing file means no kernel modules / microcode.
      ++ (
        if builtins.pathExists (hostsDir + "/${args.hostname}/hardware.nix") then
          [ (hostsDir + "/${args.hostname}/hardware.nix") ]
        else
          lib.warn
            "modules/hosts/${args.hostname}/hardware.nix is missing: the NixOS config has no hardware settings (nixos-anywhere generates it on install; see AGENTS.md)"
            [ ]
      )
      ++ lib.optional (builtins.pathExists (hostsDir + "/${args.hostname}/disko.nix")) (
        hostsDir + "/${args.hostname}/disko.nix"
      )
      ++ [
        (hostModule args profileNames // (args.nixosOptions or { }))
        { networking.hostName = args.hostname; }
      ];
    };
in
{
  flake = {
    # Every host directory under modules/hosts/ contributes its configs; the
    # meta.nix `nixos`/`home` flags say which. Hosts are discovered, so adding
    # one never touches this file.
    homeConfigurations = lib.listToAttrs (
      map (
        name:
        let
          m = hostMeta name;
        in
        lib.nameValuePair "${m.username or "smores"}@${name}" (
          mkHome ((normalize m) // { hostname = name; })
        )
      ) (lib.filter (name: (hostMeta name).home or false) hostNames)
    );
    nixosConfigurations = lib.listToAttrs (
      map (name: lib.nameValuePair name (mkNixos ((normalize (hostMeta name)) // { hostname = name; }))) (
        lib.filter (name: (hostMeta name).nixos or false) hostNames
      )
    );
  };
}
