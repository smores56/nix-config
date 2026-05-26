{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;
  hasSevenql = pkgs.stdenv.isDarwin && cfg.sevenqlLspPath != null;
  campPath = "${cfg.codeRoot}/github.com/camp-language/camp";
  hasCamp = builtins.pathExists campPath;

  camp-src =
    if hasCamp then
      fetchGit {
        url = campPath;
        rev = "318b9fb89017e8dae43a3bfedf953ce6c058e6ed";
      }
    else
      null;

  tree-sitter-camp =
    if hasCamp then
      pkgs.tree-sitter.buildGrammar {
        language = "camp";
        version = (lib.importJSON "${camp-src}/tree-sitter/tree-sitter.json").metadata.version;
        src = "${camp-src}/tree-sitter";
      }
    else
      null;
in
{
  home.packages = with pkgs; [
    ols
    nixd
    ruff
    taplo
    gopls
    nixfmt
    mdformat
    marksman
    harper
    basedpyright
    lua-language-server
    dockerfile-language-server
    yaml-language-server
    svelte-language-server
    typescript-language-server
    vscode-langservers-extracted
    graphql-language-service-cli
  ];

  home.file = lib.mkMerge [
    (lib.mkIf hasCamp {
      ".config/helix/runtime/grammars/camp.so".source = "${tree-sitter-camp}/parser";
      ".config/helix/runtime/queries/camp/highlights.scm".source =
        "${tree-sitter-camp}/queries/highlights.scm";
      ".config/helix/runtime/queries/camp/locals.scm".source = "${tree-sitter-camp}/queries/locals.scm";
      ".config/helix/runtime/queries/camp/tags.scm".source = "${tree-sitter-camp}/queries/tags.scm";
    })
    {
      ".config/helix/runtime/queries/yaml/injections.scm".source =
        pkgs.runCommand "helix-yaml-injections" { }
          ''
            cat ${pkgs.helix.passthru.runtime}/queries/yaml/injections.scm > $out
            cat >> $out << 'EXTRA'

            ((block_scalar) @injection.content
             (#match? @injection.content "function handler")
             (#set! injection.language "typescript"))

            ((block_scalar) @injection.content
             (#match? @injection.content "query.*\\{")
             (#set! injection.language "graphql"))
            EXTRA
          '';
    }
  ];

  programs.helix = {
    enable = true;
    defaultEditor = true;

    settings = {
      theme = "active";

      keys.normal = {
        C-r = [
          ":config-reload"
          ":reload-all"
          ":lsp-restart"
        ];
        C-x = ":buffer-close";
        space = {
          s = ":write";
          c = ":quit";
          t = "hover";
        };
      };

      editor = {
        cursorline = true;
        completion-replace = true;
        bufferline = "multiple";
        color-modes = true;
        jump-label-alphabet = "sntgrwfmpvcldbxieahyouk";

        end-of-line-diagnostics = "hint";
        inline-diagnostics = {
          cursor-line = "hint";
        };

        cursor-shape = {
          normal = "block";
          insert = "bar";
          select = "underline";
        };

        auto-save = {
          focus-lost = true;
          after-delay.enable = true;
        };

        whitespace.render = "all";
        indent-guides.render = true;
        soft-wrap.enable = true;
        smart-tab.enable = true;
      };
    };

    languages.language = [
      {
        name = "json";
        auto-format = false;
      }
      {
        name = "nix";
        auto-format = true;
      }
      {
        name = "typescript";
        roots = [
          "deno.json"
          "deno.jsonc"
          "package.json"
        ];
        file-types = [
          "ts"
          "tsx"
        ];
        auto-format = true;
        language-servers = [ "deno-lsp" ];
      }
      {
        name = "javascript";
        roots = [
          "deno.json"
          "deno.jsonc"
          "package.json"
        ];
        file-types = [
          "js"
          "jsx"
        ];
        auto-format = true;
        language-servers = [ "deno-lsp" ];
      }
      {
        name = "python";
        auto-format = true;
        language-servers = [
          "ruff"
          "basedpyright"
        ];
      }
      {
        name = "markdown";
        auto-format = true;
        formatter = {
          command = "mdformat";
          args = [
            "--wrap"
            "120"
            "-"
          ];
        };
        language-servers = [
          "marksman"
          "codebook"
        ];
      }
      {
        name = "yaml";
        auto-format = true;
        language-servers = [
          {
            name = "yaml-language-server";
            except-features = [ "format" ];
          }
        ]
        ++ lib.optionals hasSevenql [ "sevenql-lsp" ];
      }
    ]
    ++ lib.optionals hasCamp [
      {
        name = "camp";
        scope = "source.camp";
        file-types = [ "camp" ];
        roots = [ "camp.toml" ];
        auto-format = true;
        formatter = {
          command = "odin";
          args = [
            "run"
            "${camp-src}/src"
            "--"
            "fmt"
            "--stdin"
          ];
        };
        language-servers = [ "camp-lsp" ];
      }
    ];

    languages.language-server =
      lib.optionalAttrs hasCamp {
        camp-lsp = {
          command = "odin";
          args = [
            "run"
            "${camp-src}/src"
            "--"
            "lsp"
          ];
        };
      }
      // {
        ruff = {
          command = "ruff";
          args = [ "server" ];
        };
        basedpyright = {
          command = "basedpyright-langserver";
          args = [ "--stdio" ];
        };
        rust-analyzer.config = {
          rust-analyzer.diagnostics.disabled = [ "unresolved-proc-macro" ];
        };
        deno-lsp = {
          command = "deno";
          args = [ "lsp" ];
          config.deno = {
            enable = true;
            lint = true;
          };
        };
        codebook = {
          command = "codebook-lsp";
          args = [ "serve" ];
        };
      }
      // lib.optionalAttrs hasSevenql {
        sevenql-lsp = {
          command = "deno";
          args = [
            "run"
            "-A"
            cfg.sevenqlLspPath
          ];
        };
      };
  };
}
