{ pkgs, ... }: {
  # LSPs
  home.packages = with pkgs; [
    nil
    taplo
    gopls
    marksman
    typst-lsp
    typst-fmt
    nixpkgs-fmt
    rust-analyzer
    nodePackages.yaml-language-server
    nodePackages.svelte-language-server
    nodePackages."@prisma/language-server"
    nodePackages.typescript-language-server
    nodePackages.vscode-langservers-extracted
    nodePackages.graphql-language-service-cli
    nodePackages.dockerfile-language-server-nodejs
  ];

  stylix.targets.helix.enable = true;

  programs.helix = {
    enable = true;
    defaultEditor = true;

    settings = {
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
      {
        name = "koka";
        scope = "source.koka";
        injection-regex = "koka";
        file-types = [ "kk" ];
        roots = [ ];
        comment-token = "//";
        language-servers = [ "koka-ls" ];
        indent = { tab-width = 8; unit = "  "; };
      }
    ];

    languages.grammar = [
      {
        name = "roc";
        source = {
          git = "https://github.com/faldor20/tree-sitter-roc.git";
          rev = "381743cd40ee19a9508c6445aacb9085d4bc0cf8";
        };
      }
      {
        name = "koka";
        source = {
          git = "https://github.com/mtoohey31/tree-sitter-koka.git";
          rev = "2527e152d4b6a79fd50aebd8d0b4b4336c94a034";
        };
      }
    ];

    languages.language-server = {
      roc-ls = {
        command = "roc_language_server";
      };
      koka-ls = {
        command = "koka";
        args = [ "--language-server" ];
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
