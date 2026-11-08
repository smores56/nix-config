{
  config,
  pkgs,
  lib,
  ...
}:
let
  tsJsRoots = [
    "package.json"
  ];

  # Work keeps to the employer-approved assistant; personal hosts use the cheap maki model.
  structureRunner =
    {
      personal = {
        runner = "maki";
        model = "neuralwatt/deepseek-v4.1-flash";
      };
      work = {
        runner = "claude";
        model = "haiku";
      };
    }
    .${config.user.aiProfile};

  mdStructure = pkgs.writeShellApplication {
    name = "md-structure";
    runtimeInputs = [ pkgs.coreutils ];
    text =
      builtins.replaceStrings
        [ "@PROMPT_FILE@" "@RUNNER@" "@MODEL@" ]
        [ "${./md-structure.prompt.md}" structureRunner.runner structureRunner.model ]
        (builtins.readFile ./md-structure.sh);
  };
in
{
  # NixOS defaults EDITOR to nano, leaking into login shells and the systemd user session;
  # environment.d needs the systemd set to override the PAM-inherited value.
  home.sessionVariables = {
    EDITOR = "hx";
    VISUAL = "hx";
  };

  systemd.user.sessionVariables = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
    EDITOR = "hx";
    VISUAL = "hx";
  };

  home.packages = [
    mdStructure
  ]
  ++ (with pkgs; [
    nixd
    ruff
    taplo
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
    typescript-language-server
    vscode-langservers-extracted
  ]);

  programs.helix = {
    enable = true;

    settings = {
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
          # A non-zero exit leaves the buffer untouched.
          m = ":pipe md-structure";
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
        language-servers = [ "typescript-language-server" ];
      }
      {
        name = "javascript";
        roots = tsJsRoots;
        file-types = [
          "js"
          "jsx"
        ];
        auto-format = true;
        language-servers = [ "typescript-language-server" ];
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
        # oxide first: helix takes each feature from the first server offering it, and oxide's backlinks/tags/daily notes beat marksman.
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
    };
  };
}
