{ lib, pkgs, ... }:
let
  inherit (pkgs.stdenv) isLinux;
in
{
  home.packages = with pkgs; [
    nixd
    ruff
    taplo
    gopls
    nixfmt
    mdformat
    marksman
    basedpyright
    lua-language-server
    dockerfile-language-server
    nodePackages.yaml-language-server
    nodePackages.svelte-language-server
    nodePackages.typescript-language-server
    nodePackages.vscode-langservers-extracted
    nodePackages.graphql-language-service-cli
  ];

  home.file = {
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
  };

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
          "harper-ls"
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
        ++ lib.optionals (!isLinux) [ "sevenql-lsp" ];
      }
    ];

    languages.language-server = {
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
      harper-ls = {
        command = "harper-ls";
        args = [ "--stdio" ];
      };
    }
    // lib.optionalAttrs (!isLinux) {
      sevenql-lsp = {
        command = "deno";
        args = [
          "run"
          "-A"
          "/Users/smohr/dev/okami/typescript/tools/sevenql-lsp/main.ts"
        ];
      };
    };
  };
}
