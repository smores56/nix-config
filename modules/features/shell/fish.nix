{ pkgs, ... }:
{
  home.packages = [
    pkgs.osc
    pkgs.pfetch-rs
  ];

  home.sessionVariables = {
    async_prompt_functions = "_pure_prompt_git";
    fish_greeting = "";
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

        sl = "ssh smores@smoresnet -t fish";
        sm = "ssh smores@smortress -t fish";
        sc = "ssh smores@campfire -t fish";
        st = "ssh smores@(tailscale-hosts | fzf) -t fish";

        s = "goose session";
      };

      shellInit = ''
        fish_add_path /opt/homebrew/bin /usr/local/bin ~/.local/bin ~/.deno/bin ~/.cargo/bin ~/.opencode/bin ~/.wasmtime/bin
      '';

      interactiveShellInit = ''
        for p in $NIX_PROFILES
            set -a fish_function_path $p/share/fish/vendor_functions.d
            set -a fish_complete_path $p/share/fish/vendor_completions.d
        end
        pfetch
        function __deferred_zellij_tabname --on-event fish_prompt
            functions --erase __deferred_zellij_tabname
            __auto_zellij_update_tabname
        end

        # OpenCode remote attach function
        function o --description "Attach to smortress opencode instance"
            if test (count $argv) -gt 0
                # If argument looks like a path, use it as --dir
                if string match -q '/*' $argv[1]
                    or string match -q '~*' $argv[1]
                    opencode attach http://smortress:4000 --dir $argv[1] $argv[2..]
                else
                    # Otherwise pass all args through
                    opencode attach http://smortress:4000 $argv
                end
            else
                # Default: attach to home directory
                opencode attach http://smortress:4000
            end
        end

        # Project-specific shortcuts
        function oc --description "Attach to camp project on smortress"
            opencode attach http://smortress:4000 --dir ~/code/github.com/camp-language/camp $argv
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
