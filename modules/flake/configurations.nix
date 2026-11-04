{ inputs, mkPkgs, ... }:
let
  inherit (inputs)
    home-manager
    niri
    noctalia
    stylix
    sops-nix
    disko
    ;
  inherit (inputs.nixpkgs) lib;

  localOverlays = import ../../pkgs/overlays.nix { inherit inputs; };

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
  # a directory (default.nix + disko.nix + hardware.nix), never editing this
  # file. default.nix is data, not a module: `profiles` names the shared
  # profiles (they drive machine.graphical/wayland/workHost and the
  # server-profile assertion); `homeModules` and `nixosModules` list modules
  # that exist on that host alone, such as a LUKS chain, a greeter, or a Darwin
  # host's sops keys. Host-local modules are not profiles: their names never
  # reach machine.profiles.
  hostsDir = ../hosts;
  hostNames = builtins.attrNames (
    lib.filterAttrs (_: type: type == "directory") (builtins.readDir hostsDir)
  );
  # Catches typos in the top-level keys: a misspelled flag or options section
  # would otherwise be silently ignored.
  allowedKeys = [
    "system"
    "username"
    "nixos"
    "home"
    "user"
    "profiles"
    "homeModules"
    "nixosModules"
    "homeOptions"
    "nixosOptions"
  ];
  hostMeta =
    name:
    let
      path = hostsDir + "/${name}/default.nix";
      meta =
        if builtins.pathExists path then
          import path
        else
          throw "modules/hosts/${name}/ has no default.nix (see AGENTS.md)";
      unknown = builtins.filter (key: !(builtins.elem key allowedKeys)) (builtins.attrNames meta);
    in
    if unknown != [ ] then
      throw "modules/hosts/${name}/default.nix has unknown keys: ${lib.concatStringsSep ", " unknown}"
    else
      meta;

  profileNamesOf =
    name: map (p: lib.removeSuffix ".nix" (baseNameOf (toString p))) (hostMeta name).profiles;

  profileModules = name: kind: lib.concatMap (p: (import p).${kind} or [ ]) (hostMeta name).profiles;

  hostModules = name: (hostMeta name).nixosModules or [ ];
  hostHomeModules = name: (hostMeta name).homeModules or [ ];

  hostModule = args: profileNames: {
    machine = {
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
      inherit (args) system username;
      profileNames = profileNamesOf args.hostname;
    in
    home-manager.lib.homeManagerConfiguration {
      pkgs = pkgsForSystem system;
      extraSpecialArgs = {
        inherit inputs;
      };
      modules =
        homeModules
        ++ profileModules args.hostname "home"
        ++ hostHomeModules args.hostname
        ++ [
          (hostModule args profileNames // (args.homeOptions or { }))
          {
            home.username = username;
            home.homeDirectory =
              if lib.hasSuffix "-darwin" system then "/Users/${username}" else "/home/${username}";
          }
        ];
    };

  mkNixos =
    args:
    let
      inherit (args) system;
      profileNames = profileNamesOf args.hostname;
    in
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = { inherit inputs; };
      modules = [
        { nixpkgs.overlays = localOverlays system; }
      ]
      ++ nixosModules
      ++ profileModules args.hostname "nixos"
      ++ hostModules args.hostname
      ++ lib.optionals (builtins.elem "linux-desktop" profileNames) [ niri.nixosModules.niri ]
      # hardware.nix is optional so a host can be authored (default.nix +
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
    # default.nix `nixos`/`home` flags say which. Hosts are discovered, so adding
    # one never touches this file.
    homeConfigurations = lib.listToAttrs (
      map (
        name:
        let
          m = normalize (hostMeta name);
        in
        lib.nameValuePair "${m.username}@${name}" (mkHome (m // { hostname = name; }))
      ) (lib.filter (name: (hostMeta name).home or false) hostNames)
    );
    nixosConfigurations = lib.listToAttrs (
      map (name: lib.nameValuePair name (mkNixos ((normalize (hostMeta name)) // { hostname = name; }))) (
        lib.filter (name: (hostMeta name).nixos or false) hostNames
      )
    );
  };
}
