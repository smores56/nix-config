{ pkgs }:
let
  inherit (pkgs) lib;
  evaluate =
    {
      enable,
      profile,
      darwin,
    }:
    lib.evalModules {
      specialArgs.pkgs = pkgs // {
        stdenv = pkgs.stdenv // {
          hostPlatform = pkgs.stdenv.hostPlatform // {
            isDarwin = darwin;
          };
        };
      };
      modules = [
        ../modules/features/ai/slack-mcp
        {
          options = {
            user.aiProfile = lib.mkOption { type = lib.types.str; };
            home.packages = lib.mkOption {
              type = lib.types.listOf lib.types.package;
              default = [ ];
            };
            home.file = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
              default = { };
            };
            assertions = lib.mkOption {
              type = lib.types.listOf lib.types.anything;
              default = [ ];
            };
          };
          config = {
            slackMcp.enable = enable;
            user.aiProfile = profile;
          };
        }
      ];
    };
  work =
    (evaluate {
      enable = true;
      profile = "work";
      darwin = true;
    }).config;
  disabled =
    (evaluate {
      enable = false;
      profile = "work";
      darwin = true;
    }).config;
  personal =
    (evaluate {
      enable = true;
      profile = "personal";
      darwin = true;
    }).config;
  linux =
    (evaluate {
      enable = true;
      profile = "work";
      darwin = false;
    }).config;
  permitted = config: lib.all (item: item.assertion) config.assertions;
in
assert permitted work;
assert !permitted personal;
assert !permitted linux;
assert disabled.home.file == { };
assert disabled.home.packages == [ ];
assert builtins.length work.home.packages == 1;
assert
  lib.sort builtins.lessThan (builtins.attrNames work.home.file) == [
    ".agents/skills/native-slack"
    ".config/maki/mcp.toml"
  ];
pkgs.runCommand "slack-mcp-module-check"
  {
    nativeBuildInputs = [ pkgs.python3 ];
    mcpConfig = work.home.file.".config/maki/mcp.toml".source;
  }
  ''
    python - "$mcpConfig" <<'PY'
    import pathlib
    import sys
    import tomllib

    config = tomllib.loads(pathlib.Path(sys.argv[1]).read_text())
    assert set(config) == {"mcp"}
    assert set(config["mcp"]) == {"slack"}
    slack = config["mcp"]["slack"]
    assert slack["enabled"] is True
    assert slack["timeout"] == 120000
    assert len(slack["command"]) == 2
    assert slack["command"][0].startswith("/nix/store/")
    assert slack["command"][0].endswith("/bin/maki-slack")
    assert slack["command"][1] == "serve"
    PY
    if NODE_OPTIONS='--require=/missing-slack-test-module' NODE_DEBUG=child_process \
      ${lib.getExe (builtins.head work.home.packages)} auth --invalid >stdout 2>stderr; then
      exit 1
    fi
    test ! -s stdout
    grep -q 'Usage: node session.mjs' stderr
    if grep -Eq 'missing-slack-test-module|CHILD_PROCESS|envPairs' stderr; then
      exit 1
    fi
    touch "$out"
  ''
