{ lib, pkgs, ... }@args:
{
  # LSPs
  home.packages = with pkgs; [
    nixd
    taplo
    gopls
    nixfmt
    starpls
    mdformat
    marksman
    lua-language-server
    dockerfile-language-server
    nodePackages.yaml-language-server
    nodePackages.svelte-language-server
    nodePackages.typescript-language-server
    nodePackages.vscode-langservers-extracted
    nodePackages.graphql-language-service-cli
  ];

  # Add TypeScript highlighting for YAML-sourced flow handlers
  home.file = {
    ".config/helix/runtime/queries/yaml/injections.scm".text = ''
      ${builtins.readFile "${pkgs.helix}/lib/runtime/queries/yaml/injections.scm"}

      ((block_scalar) @injection.content
       (#match? @injection.content "function handler")
       (#set! injection.language "typescript"))

      ((block_scalar) @injection.content
       (#match? @injection.content "query.*\\{")
       (#set! injection.language "graphql"))
    '';
  };

  stylix.targets.helix.enable = !args ? helixTheme;

  programs.helix = {
    enable = true;
    defaultEditor = true;

    settings = {
      theme = lib.mkIf (args ? helixTheme) args.helixTheme;

      keys.normal.C-r = [
        ":config-reload"
        ":reload-all"
        ":lsp-restart"
      ];

      keys.normal.C-x = ":buffer-close";

      keys.normal.space = {
        s = ":write";
        c = ":quit";
        t = "hover";
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
        name = "python";
        auto-format = true;
        language-servers = [
          "ruff"
          "basedpyright"
        ];
      }
      {
        name = "starlark";
        auto-format = true;
      }
      {
        name = "json";
        auto-format = false;
      }
      {
        name = "svelte";
        auto-format = true;
        roots = [ "package.json" ];
      }
      {
        name = "java";
        indent = {
          tab-width = 4;
          unit = "    ";
        };
      }
      {
        name = "nix";
        auto-format = true;
      }
      {
        name = "tsx";
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
    ];

    languages.language-server = {
      ruff = {
        command = "uvx";
        args = [
          "run"
          "ruff"
          "server"
        ];
      };
      basedpyright = {
        command = "uvx";
        args = [
          "run"
          "basedpyright-langserver"
          "--stdio"
        ];
      };
      pylsp.config = {
        pylsp.plugins = {
          ruff.enabled = true;
          black.enabled = true;
        };
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
    };
  };
}
