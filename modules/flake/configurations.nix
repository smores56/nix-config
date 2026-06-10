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
            ticketPrefix = null;
            workGithubOrgs = null;
            workModels = null;
            sevenqlLspPath = null;
            opencodeHost = null;
            paseo = null;
            ohMyPi = null;
            herdr = null;
            hermes = null;
            maki = null;
            tau = null;

            pi = null;
            piDashboard = null;
            agentOfEmpires = null;
            llmTokenBucketProxy = null;
            goose = null;
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
            opencodeHost = args.opencodeHost or { };
            paseo = args.paseo or { };
            herdr = args.herdr or { };
            hermes = args.hermes or { };
            piDashboard = args.piDashboard or { };
            webProxy = args.webProxy or { };
            agentOfEmpires = args.agentOfEmpires or { };
            tau = args.tau or { };
            goose = args.goose or { };
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
        opencodeHost = {
          hostname = "smortress";
          bindAddress = "0.0.0.0";
          opencodePort = 4000;
          openchamberPort = 3000;
        };
        paseo.enable = true;
        herdr.enable = true;
        hermes.enable = true;
        pi = {
          enable = true;
        };
        piDashboard = {
          enable = true;
        };
        agentOfEmpires = {
          enable = true;
        };
        llmTokenBucketProxy.enable = true;
        goose = {
          server.enable = true;
          web.enable = true;
        };
      };
      "smohr@smoreswork" = mkHome {
        displayManager = "osx";
        windowManager = "aerospace";
        username = "smohr";
        system = "aarch64-darwin";
        terminalFontSize = 14;
        email = "sam.mohr@sevenai.com";
        branchPrefix = "sam.mohr";
        ticketPrefix = "7AI";
        workGithubOrgs = [ "OkamiAI" ];
        workModels = true;
        sevenqlLspPath = "/Users/smohr/dev/okami/typescript/tools/sevenql-lsp/main.ts";
        maki = {
          models = [
            {
              spec = "openai/gpt-5.5-codex";
              name = "GPT 5.5 Codex";
            }
            {
              spec = "anthropic/claude-opus-4-8";
              name = "Claude Opus 4.8";
            }
          ];
          defaultModel = "openai/gpt-5.5-codex";
        };
        ohMyPi = {
          codex.enable = true;
          claude.enable = true;
        };
        pi = {
          enable = true;
          defaultProvider = "anthropic";
          defaultModel = "claude-fable-5";
          # Slack via korotovsky/slack-mcp-server, read-only (no
          # SLACK_MCP_ADD_MESSAGE_TOOL). Auth: browser session tokens in
          # ~/.config/fish/conf.d/api-keys.fish, set up via `slack-mcp-auth`
          # (auto-extracts from Slack.app; re-run when the session expires).
          # The adapter interpolates ${...} from the environment at runtime.
          mcpServers.slack = {
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
        opencodeHost = {
          hostname = "smortress";
          bindAddress = "0.0.0.0";
          opencodePort = 4000;
          openchamberPort = 3000;
        };
        paseo = {
          enable = true;
          web.enable = true;
        };
        herdr.enable = true;
        hermes.enable = true;
        piDashboard = {
          enable = true;
        };
        webProxy = {
          enable = true;
          tunnelId = "f2284d1b-5038-447b-ab50-e18dc1dba8c5";
        };
        agentOfEmpires = {
          enable = true;
        };
        goose.web.enable = true;
      };
    };
  };
}
