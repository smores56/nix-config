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
    nodePackages.yaml-language-server
    nodePackages.svelte-language-server
    nodePackages."@prisma/language-server"
    nodePackages.typescript-language-server
    nodePackages.vscode-langservers-extracted
    nodePackages.graphql-language-service-cli
    nodePackages.dockerfile-language-server-nodejs
  ];

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
        indent = { tab-width = 8; unit = "  "; };
      }
      {
        name = "erg";
        scope = "source.erg";
        injection-regex = "erg";
        file-types = [ "er" ];
        roots = [ ];
        comment-token = "#";
        language-servers = [ "els" ];
        indent = { tab-width = 4; unit = "    "; };

        auto-pairs = {
          "(" = ")";
          "{" = "}";
          "[" = "]";
          "'" = "'";
          "\"" = "\"";
        };
      }
    ];

    languages.grammar = [
      {
        name = "roc";
        source = {
          git = "https://github.com/faldor20/tree-sitter-roc.git";
          rev = "2c985e01fd1eae1e8ce0d52b084a6b555c26048e";
        };
      }
      {
        name = "koka";
        source = {
          git = "https://github.com/mtoohey31/tree-sitter-koka.git";
          rev = "bae18088ab7b6938b11640c468ca35618d215830";
        };
      }
    ];

    languages.language-server = {
      roc-ls = {
        command = "roc_ls";
      };
      koka-lsp = {
        command = "koka";
        args = [ "language-server" ];
      };
      els = {
        command = "erg";
        args = [ "server" ];
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
