{
  pkgs,
  lib,
  ...
}:
let
  tsJsRoots = [
    "deno.json"
    "deno.jsonc"
    "package.json"
  ];
in
{
  # NixOS defaults EDITOR to nano (environment.variables in nixpkgs), which
  # leaks into login shells and, via the systemd user session, into
  # GUI-spawned processes. home.sessionVariables covers shells; the systemd
  # set is what environment.d needs to override the PAM-inherited value.
  home.sessionVariables = {
    EDITOR = "hx";
    VISUAL = "hx";
  };

  systemd.user.sessionVariables = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
    EDITOR = "hx";
    VISUAL = "hx";
  };

  home.packages = with pkgs; [
    nixd
    ruff
    taplo
    gopls
    nixfmt
    # wikilink keeps mdformat from escaping [[links]] into \[[links]\].
    (mdformat.withPlugins (p: [
      p.mdformat-gfm
      p.mdformat-wikilink
    ]))
    markdown-oxide
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

  programs.helix = {
    enable = true;

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
        roots = tsJsRoots;
        file-types = [
          "ts"
          "tsx"
        ];
        auto-format = true;
        language-servers = [ "deno-lsp" ];
      }
      {
        name = "javascript";
        roots = tsJsRoots;
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
        # oxide first: helix takes each feature from the first server offering it,
        # and oxide's backlinks, tags, and daily notes beat marksman's plain links.
        language-servers = [
          "markdown-oxide"
          "marksman"
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
        ];
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
    };
  };
}
