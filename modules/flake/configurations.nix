{ inputs, ... }:
let
  inherit (inputs)
    home-manager
    niri
    noctalia
    concord
    stylix
    smolvm
    ;
  inherit (inputs.nixpkgs) lib;

  importTree = path: (inputs.import-tree path).imports;

  localOverlays = system: [
    niri.overlays.niri
    smolvm.overlays.default
    (final: prev: {
      # Override libkrun to build without GPU support. The upstream flake
      # builds with withGpu=isLinux, producing a libkrun.so with undefined
      # virgl_renderer_* symbols (libkrun.so doesn't list libvirglrenderer
      # as NEEDED, and the rpath lacks it). No-GPU is correct for headless
      # agent VMs anyway.
      smolvm-libkrun = prev.smolvm-libkrun.override {
        withGpu = false;
      };

      # Patch the smolvm release tarball:
      # 1. Replace the bundled libkrun.so (GPU-enabled, broken virgl symbols)
      #    with our no-GPU build from smolvm-libkrun.
      # 2. Create missing /mnt mount points in agent-rootfs that
      #    setup_persistent_rootfs() needs at boot (the 0.8.2 release
      #    tarball wasn't rebuilt with the build-agent-rootfs.sh fix).
      smolvm = prev.smolvm.overrideAttrs (old: {
        postInstall = (old.postInstall or "") + ''
          rm -f $out/libexec/smolvm/lib/libkrun.so $out/libexec/smolvm/lib/libkrun.so.1 $out/libexec/smolvm/lib/libkrun.so.2
          cp -f ${final.smolvm-libkrun}/lib64/libkrun.so.1.17.3 $out/libexec/smolvm/lib/libkrun.so.1.17.3
          ln -sf libkrun.so.1.17.3 $out/libexec/smolvm/lib/libkrun.so.1
          ln -sf libkrun.so.1 $out/libexec/smolvm/lib/libkrun.so

          for d in overlay storage newroot virtiofs rosetta; do
            mkdir -p $out/libexec/smolvm/agent-rootfs/mnt/$d
          done
        '';
      });

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
    })
  ];

  pkgsForSystem =
    system:
    import inputs.nixpkgs {
      inherit system;
      config.allowUnfree = true;
      overlays = localOverlays system ++ [ noctalia.overlays.default ];
    };

  homeModules = [
    ../options.nix
    ../home.nix
  ]
  ++ importTree ../features
  ++ importTree ../desktop
  ++ [
    niri.homeModules.niri
    noctalia.homeModules.default
    stylix.homeModules.stylix
  ];

  nixosModules = [ ../options.nix ] ++ importTree ../nixos;

  mkHome =
    args:
    let
      system = args.system or "x86_64-linux";
      username = args.username or "smores";
    in
    home-manager.lib.homeManagerConfiguration {
      pkgs = pkgsForSystem system;
      extraSpecialArgs = {
        inherit inputs;
      };
      modules = homeModules ++ [
        {
          dotfiles = {
            inherit username;
          }
          // builtins.intersectAttrs {
            displayManager = "none";
            windowManager = "none";
            terminalFontSize = null;
            polarity = null;
            exposeSsh = null;
            nixos = null;
            email = null;
            llm = null;
            noSleep = null;
            primaryMonitor = null;
            monitorSize = null;
            workBranchPrefix = null;
            ticketPrefix = null;
            workGithubOrgs = null;
            workModels = null;
            sevenqlLspPath = null;
            ohMyPi = null;
            maki = null;
          } args;
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
      dm = args.displayManager or "none";
      username = args.username or "smores";
    in
    inputs.nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        { nixpkgs.overlays = localOverlays (args.system or "x86_64-linux"); }
      ]
      ++ nixosModules
      ++ [
        ../hosts/${args.hostname}.nix
        {
          networking.hostName = args.hostname;
          dotfiles = {
            inherit username;
            displayManager = dm;
            exposeSsh = args.exposeSsh or false;
            fingerprint = args.fingerprint or false;
            nvidia = args.nvidia or false;
            llm = args.llm or false;
            noSleep = args.noSleep or false;
            persist = args.persist or false;
            webProxy = args.webProxy or { };
          };
        }
      ]
      ++ (if dm == "niri" then [ niri.nixosModules.niri ] else [ ]);
    };
in
{
  flake = {
    homeConfigurations = {
      "smores@smorestux" = mkHome {
        displayManager = "niri";
        nixos = true;
      };
      "smores@smoresbook" = mkHome {
        displayManager = "niri";
        nixos = true;
        polarity = "time-of-day";
        primaryMonitor = "eDP-1";
        monitorSize = {
          width = 1920;
          height = 1080;
        };
      };
      "smores@campfire" = mkHome {
        displayManager = "niri";
        nixos = true;
        polarity = "time-of-day";
        noSleep = true;
      };
      "smores@smortress" = mkHome {
        displayManager = "none";
        nixos = true;
      };
      "smohr@smoreswork" =
        let
          gleanServerUrl = "https://sevenai-be.glean.com";
          gleanMcpServer = {
            command = "npx";
            args = [
              "-y"
              "@gleanwork/local-mcp-server"
            ];
            env = {
              GLEAN_SERVER_URL = gleanServerUrl;
              GLEAN_API_TOKEN = "\${GLEAN_API_TOKEN}";
            };
          };
          basicMemoryMcpEnv = {
            BASIC_MEMORY_SEMANTIC_SEARCH_ENABLED = "true";
            BASIC_MEMORY_SEMANTIC_EMBEDDING_PROVIDER = "fastembed";
          };
        in
        mkHome {
          displayManager = "osx";
          windowManager = "aerospace";
          username = "smohr";
          system = "aarch64-darwin";
          terminalFontSize = 16;
          email = "sam.mohr@sevenai.com";
          workBranchPrefix = "sam.mohr";
          ticketPrefix = "7AI";
          workGithubOrgs = [ "OkamiAI" ];
          workModels = true;
          sevenqlLspPath = "/Users/smohr/dev/okami/typescript/tools/sevenql-lsp/main.ts";
          ohMyPi = {
            codex.enable = true;
            mcpServers = {
              glean = gleanMcpServer;
              "basic-memory" = {
                command = "uvx";
                args = [
                  "basic-memory"
                  "mcp"
                ];
                env = basicMemoryMcpEnv;
              };
            };
          };
          maki = {
            cloudflareWorkersAi.enable = true;
            mcpServers = {
              glean.command = [
                "env"
                "GLEAN_SERVER_URL=${gleanServerUrl}"
                "npx"
                "-y"
                "@gleanwork/local-mcp-server"
              ];
              slack.command = [
                "sh"
                "-lc"
                ''
                  cache_dir="''${XDG_CACHE_HOME:-$HOME/.cache}/slack-mcp-server"
                  mkdir -p "$cache_dir"
                  export SLACK_MCP_USERS_CACHE="$cache_dir/users_cache.json"
                  export SLACK_MCP_CHANNELS_CACHE="$cache_dir/channels_cache_v2.json"
                  exec npx -y slack-mcp-server@latest --transport stdio
                ''
              ];
            };
          };
        };
    };
    nixosConfigurations = {
      "campfire" = mkNixos {
        hostname = "campfire";
        displayManager = "niri";
        exposeSsh = true;
        noSleep = true;
      };
      "smorestux" = mkNixos {
        hostname = "smorestux";
        displayManager = "niri";
      };
      "smoresbook" = mkNixos {
        hostname = "smoresbook";
        displayManager = "niri";
        fingerprint = true;
      };
      "smortress" = mkNixos {
        hostname = "smortress";
        displayManager = "none";
        nvidia = true;
        llm = true;
        noSleep = true;
        webProxy = {
          enable = true;
          tunnelId = "f2284d1b-5038-447b-ab50-e18dc1dba8c5";
        };
      };
    };
  };
}
