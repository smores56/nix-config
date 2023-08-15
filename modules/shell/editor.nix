{ pkgs, ... }: {
  # LSPs
  home.packages = with pkgs; [
    kakoune

    taplo
    gopls
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
      # TODO: set programmatically
      theme = "rose_pine_moon";

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
        name = "rust";
        config.rust-analyzer.diagnostics.disabled = [ "unresolved-proc-macro" ];
      }
    ];
  };
}
