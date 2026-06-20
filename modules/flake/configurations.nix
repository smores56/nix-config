{ inputs, ... }:
let
  inherit (inputs)
    home-manager
    niri
    noctalia
    paneru
    concord
    stylix
    ;
  inherit (inputs.nixpkgs) lib;

  importTree = path: (inputs.import-tree path).imports;

  pkgsForSystem =
    system:
    import inputs.nixpkgs {
      inherit system;
      config.allowUnfree = true;
      overlays = [
        niri.overlays.niri
        noctalia.overlays.default
        (final: prev: {
          concord = concord.packages.${system}.default;
          # pkgs.nono's test suite fails to build on darwin: the Nix sandbox sets
          # $HOME under /nix and nono's system_read_macos group grants /nix, so the
          # deprecated_schema dry-run tests refuse to start (state root .nono under
          # /nix overlaps the granted /nix). The binary is fine; skip its checks.
          nono = prev.nono.overrideAttrs (_: lib.optionalAttrs prev.stdenv.isDarwin { doCheck = false; });
        })
      ];
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
    paneru.homeModules.paneru
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
            darkTheme = null;
            lightTheme = null;
            llm = null;
            noSleep = null;
            primaryMonitor = null;
            monitorSize = null;
            branchPrefix = null;
            workBranchPrefix = null;
            ticketPrefix = null;
            workGithubOrgs = null;
            workModels = null;
            sevenqlLspPath = null;
            ohMyPi = null;

            pi = null;
            piDashboard = null;
            llmTokenBucketProxy = null;
            maki = null;
            zerostack = null;
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
        { nixpkgs.overlays = [ niri.overlays.niri ]; }
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
            piDashboard = args.piDashboard or { };
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
        pi = {
          enable = true;
        };
        piDashboard = {
          enable = true;
        };
        llmTokenBucketProxy.enable = true;
        maki.byteroverMemory = true;
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
          slackMcpServer = {
            command = "npx";
            args = [
              "-y"
              "slack-mcp-server@latest"
              "--transport"
              "stdio"
            ];
            env = {
              SLACK_MCP_XOXC_TOKEN = "\${SLACK_MCP_XOXC_TOKEN}";
              SLACK_MCP_XOXD_TOKEN = "\${SLACK_MCP_XOXD_TOKEN}";
            };
          };
        in
        mkHome {
          displayManager = "osx";
          windowManager = "aerospace";
          username = "smohr";
          system = "aarch64-darwin";
          terminalFontSize = 14;
          email = "sam.mohr@sevenai.com";
          workBranchPrefix = "sam.mohr";
          ticketPrefix = "7AI";
          workGithubOrgs = [ "OkamiAI" ];
          workModels = true;
          sevenqlLspPath = "/Users/smohr/dev/okami/typescript/tools/sevenql-lsp/main.ts";
          ohMyPi = {
            codex.enable = true;
            claude.enable = false;
            mcpServers.glean = gleanMcpServer;
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
                "npx"
                "-y"
                "slack-mcp-server@latest"
                "--transport"
                "stdio"
              ];
            };
          };
          pi = {
            enable = true;
            defaultProvider = "openai-codex";
            defaultModel = "gpt-5.5";
            # Slack via korotovsky/slack-mcp-server, read-only (no
            # SLACK_MCP_ADD_MESSAGE_TOOL). Auth: browser session tokens in
            # ~/.config/fish/conf.d/api-keys.fish, set up via `slack-mcp-auth`
            # (auto-extracts from Slack.app; re-run when the session expires).
            # The adapter interpolates ${...} from the environment at runtime.
            mcpServers.slack = slackMcpServer;
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
        piDashboard = {
          enable = true;
        };
        webProxy = {
          enable = true;
          tunnelId = "f2284d1b-5038-447b-ab50-e18dc1dba8c5";
        };
      };
    };
  };
}
