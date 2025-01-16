{ lib, pkgs, helixTheme, displayManager, ... }: {
  # LSPs
  home.packages = with pkgs; [
    nil
    zls
    taplo
    gopls
    marksman
    typst-lsp
    typst-fmt
    nixpkgs-fmt
    rust-analyzer
    nodePackages.yaml-language-server
    nodePackages.svelte-language-server
    nodePackages.typescript-language-server
    nodePackages.vscode-langservers-extracted
    nodePackages.graphql-language-service-cli
    nodePackages.dockerfile-language-server-nodejs
  ];

  stylix.targets.helix.enable = lib.mkIf (displayManager != null) (helixTheme == null);

  programs.helix = {
    enable = true;
    defaultEditor = true;

    settings = {
      theme = if helixTheme == null then "" else helixTheme;

      keys.normal.space = {
        s = ":write";
        c = ":quit";
        t = "hover";
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
      { name = "tsx"; auto-format = true; }
      { name = "nix"; auto-format = true; }
      { name = "python"; auto-format = true; }
      { name = "javascript"; auto-format = true; }
      { name = "typescript"; auto-format = true; }
      { name = "json"; auto-format = false; }
      { name = "svelte"; auto-format = true; roots = [ "package.json" ]; }
      { name = "java"; indent = { tab-width = 4; unit = "    "; }; }
      {
        name = "roc";
        scope = "source.roc";
        injection-regex = "roc";
        file-types = [ "roc" ];
        shebangs = [ "roc" ];
        roots = [ ];
        comment-token = "#";
        language-servers = [ "roc-ls" ];
        indent = { tab-width = 4; unit = "    "; };
        auto-format = true;
        formatter = {
          command = "roc";
          args = [ "format" "--stdin" "--stdout" ];
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
      pylsp.config = {
        pylsp.plugins = {
          ruff.enabled = true;
          black.enabled = true;
        };
      };
      rust-analyzer.config = {
        rust-analyzer.diagnostics.disabled = [ "unresolved-proc-macro" ];
      };
    };
  };
}
