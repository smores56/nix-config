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
    python311Packages.mypy
    python311Packages.python-lsp-server
    nodePackages.svelte-language-server
    nodePackages.yaml-language-server
    nodePackages.typescript-language-server
    nodePackages.vscode-langservers-extracted
    nodePackages.dockerfile-language-server-nodejs
  ];

  programs.helix = {
    enable = true;
    defaultEditor = true;

    settings = {
      theme = "base16_transparent";

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
      { name = "javascript"; auto-format = true; }
      { name = "typescript"; auto-format = true; }
      { name = "svelte"; auto-format = true; roots = [ "package.json" ]; }
      { name = "java"; indent = { tab-width = 4; unit = "    "; }; }
      {
        name = "roc";
        scope = "source.roc";
        injection-regex = "roc";
        file-types = ["roc"];
        shebangs = ["roc"];
        roots = [];
        comment-token = "#";
        language-servers = ["roc-ls"];
        indent = { tab-width = 4; unit = "    "; };

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
          rev = "2c985e01fd1eae1e8ce0d52b084a6b555c26048e";
        };
      }
    ];

    languages.language-server = {
      roc-ls = {
        command = "roc_ls";
      };
      rust-analyzer = {
        config.rust-analyzer.diagnostics.disabled = [ "unresolved-proc-macro" ];
      };
    };
  };
}
