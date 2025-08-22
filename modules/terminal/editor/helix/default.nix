{ lib, pkgs, ... }@args:
{
  # LSPs
  home.packages = with pkgs; [
    zls
    nixd
    taplo
    gopls
    lsp-ai
    marksman
    tinymist
    typst-fmt
    starpls-bin
    rust-analyzer
    nixfmt-rfc-style
    lua-language-server
    kotlin-language-server
    python313Packages.python-lsp-server
    nodePackages.yaml-language-server
    nodePackages.svelte-language-server
    nodePackages.typescript-language-server
    nodePackages.vscode-langservers-extracted
    nodePackages.graphql-language-service-cli
    nodePackages.dockerfile-language-server-nodejs
  ];

  stylix.targets.helix.enable = !args ? helixTheme;

  programs.helix = {
    enable = true;
    defaultEditor = true;

    settings = {
      theme = lib.mkIf (args ? helixTheme) args.helixTheme;

      keys.normal.C-r = [
        ":config-reload"
        ":reload-all"
      ];

      keys.normal.space = {
        s = ":write";
        c = ":quit";
        t = "hover";
        o = [
          ":sh rm -f /tmp/yazi-helix-context"
          ":insert-output yazi %{buffer_name} --chooser-file=/tmp/yazi-helix-context"
          ":insert-output echo \"\\x1b[?1049h\\x1b[?2004h\" > /dev/tty"
          ":open %sh{cat /tmp/yazi-helix-context}"
          ":redraw"
        ];
      };

      editor = {
        cursorline = true;
        bufferline = "multiple";
        color-modes = true;

        file-picker.hidden = false;
        indent-guides.render = true;
        soft-wrap.enable = true;

        end-of-line-diagnostics = "hint";
        inline-diagnostics = {
          cursor-line = "error";
          # other-lines = "error";
        };

        lsp = {
          display-messages = true;
          display-inlay-hints = false;
        };

        whitespace.render = {
          space = "all";
          tab = "all";
        };

        cursor-shape = {
          normal = "block";
          insert = "bar";
          select = "underline";
        };
      };
    };

    languages.language = [
      {
        name = "markdown";
        language-servers = [ "lsp-ai" ];
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
        formatter = {
          command = "nixfmt";
        };
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
        language-servers = [
          "deno-lsp"
          "lsp-ai"
        ];
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
        name = "roc";
        scope = "source.roc";
        injection-regex = "roc";
        file-types = [ "roc" ];
        shebangs = [ "roc" ];
        roots = [ ];
        comment-token = "#";
        language-servers = [ "roc-ls" ];
        indent = {
          tab-width = 4;
          unit = "    ";
        };
        auto-format = true;
        formatter = {
          command = "roc";
          args = [
            "format"
            "--stdin"
            "--stdout"
          ];
        };

        auto-pairs = {
          "(" = ")";
          "{" = "}";
          "[" = "]";
          "\"" = "\"";
        };
      }
    ];

    languages.grammar = [
      {
        name = "roc";
        source = {
          git = "https://github.com/faldor20/tree-sitter-roc.git";
          rev = "ef46edd0c03ea30a22f7e92bc68628fb7231dc8a";
        };
      }
    ];

    languages.language-server = {
      roc-ls = {
        command = "roc_language_server";
      };
      ruff = {
        command = "uv";
        args = [
          "run"
          "ruff"
          "server"
        ];
      };
      basedpyright = {
        command = "uv";
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
        config.deno.enable = true;
      };

      lsp-ai = import ./lsp-ai.nix { };
    };
  };
}
