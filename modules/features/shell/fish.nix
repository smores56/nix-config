{ pkgs, ... }:
{
  home = {
    packages = [
      pkgs.osc
      pkgs.pfetch-rs
    ];

    sessionVariables = {
      async_prompt_functions = "_pure_prompt_git";
      fish_greeting = "";
    };

    sessionPath = [
      "/opt/homebrew/bin"
      "/usr/local/bin"
      "~/.local/bin"
      "~/.deno/bin"
      "~/.cargo/bin"
      "~/.bun/bin"
      "~/.cache/.bun/bin"
      "~/.opencode/bin"
      "~/.wasmtime/bin"
    ];
  };

  manual.manpages.enable = false;

  programs = {
    zoxide = {
      enable = true;
      options = [
        "--cmd"
        "c"
      ];
    };

    man.generateCaches = false;

    fish = {
      enable = true;
      generateCompletions = false;

      shellAbbrs = {
        e = "hx";
        ef = "tv | read -l f; and hx $f";
        et = "tv text | read -l f; and hx $f";
        l = "eza --icons -lh";
        t = "zellij";
        a = "mkdir -p";
        f = "yazi";
        b = "bat";
        g = "lazygit";
        gs = "gh dash";
        gn = "gh notify";
        gp = "gh pr create";
        copy = "osc copy";
        paste = "osc paste";

        cn = "c ~/code/github.com/smores56/nix-config";
        hm = "home-manager";
        hs = "home-manager switch --no-write-lock-file";

        ns = "sudo nixos-rebuild --flake ~/.config/home-manager switch --upgrade";
        nsr = "nix-store --repair --verify --check-contents";
        ng = "nix-collect-garbage";

        sm = "ssh smores@smortress -t fish";
        st = "ssh smores@(tailscale-hosts | fzf) -t fish";

        o = "opencode";
      };

      interactiveShellInit = ''
        for p in $NIX_PROFILES
            set -a fish_function_path $p/share/fish/vendor_functions.d
            set -a fish_complete_path $p/share/fish/vendor_completions.d
        end
        # Skip pfetch in OpenChamber - ANSI codes corrupt fenv.main parsing
        if not set -q TERM_PROGRAM; or ! string match -q "*OpenChamber*" $TERM_PROGRAM
            pfetch
        end
        function __deferred_zellij_tabname --on-event fish_prompt
            functions --erase __deferred_zellij_tabname
            __auto_zellij_update_tabname
        end
      '';

      plugins =
        map
          (name: {
            inherit name;
            inherit (pkgs.fishPlugins.${name}) src;
          })
          [
            "done"
            "pure"
            "async-prompt"
          ];
    };
  };
}
