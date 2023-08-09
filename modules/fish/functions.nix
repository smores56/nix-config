{ ... }: {
  programs.fish.functions = {
    error = {
      description = "Print error to stderr";
      body = ''
        echo (tput setaf 1)"error: $argv"(tput sgr0) 1>&2
        return 1
      '';
    };
    lfcd = {
      description = "Open a file manager and cd to last directory opened on close";
      body = ''
        set tmp (mktemp)
        # `command` is needed in case `lfcd` is aliased to `lf`
        command lf -last-dir-path=$tmp $argv
        if test -f "$tmp"
            set dir (cat $tmp)
            rm -f $tmp
            if test -d "$dir"
                if test "$dir" != (pwd)
                    cd $dir
                end
            end
        end
      '';
    };
    port-forward = {
      description = "Port forward through SSH server";
      body = ''
        if test (count $argv) -gt 0
            set SshLocation $argv[1]
        else
            return (error "Must specify where to port forward")
        end

        set InternalPort ( if test (count $argv) -gt 1; echo $argv[2]; else; echo 3000; end )
        set ExternalPort ( if test (count $argv) -gt 2; echo $argv[3]; else; echo 80; end )

        ssh -gfNR "$ExternalPort:127.0.0.1:$InternalPort" "$SshLocation"
      '';
    };
    set-theme = {
      description = "Set the system theme";
      body = ''
        argparse --min-args=1 "s/select" -- $argv
        or return

        set theme $argv[1]
        if test "$theme" != "light" -a "$theme" != "dark"
            return (error "theme must be `light` or `dark`")
        end

        if test -z "$_flag_select"
            if test $theme = "light"
                set variant "rose_pine_dawn"
            else
                set variant "rose_pine_moon"
            end
        else
            set variants (ls ~/.config/alacritty/"$theme"/*.yml | xargs basename -a -s .yml)
            set variant (gum choose --header="Pick a $theme theme" $variants)
            or return (error "Must pick a variant")
        end

        mkdir -p ~/.config/helix/themes/
        ln -sf ~/.config/lazygit/"$theme-config.yml" ~/.config/lazygit/config.yml
        ln -sf ~/.config/alacritty/"$theme/$variant.yml" ~/.config/alacritty/theme.yml
        ln -sf ~/.config/alacritty/"$theme/$variant.yml" ~/.theme.yml

        if test (uname) = "Darkin"
            ln -sf /opt/homebrew/opt/helix/libexec/runtime/themes/"$variant.toml" ~/.config/helix/themes/theme.toml
        else
            ln -sf /lib/helix/runtime/themes/"$variant.toml" ~/.config/helix/themes/theme.toml
            qtile cmd-obj -o cmd -f reload_config
        end
      '';
    };
    set-wallpaper = {
      description = "Set the desktop background image";
      body = ''
        set wallpaper (ls ~/Pictures/wallpapers/* | gum choose --header="Pick a wallpaper")
        or return (error "Must choose a wallpaper")

        ln -sf "$wallpaper" ~/.wallpaper
        qtile cmd-obj -o cmd -f reload_config
      '';
    };
    zellij-picker = {
      description = "Pick a Zellij session";
      body = ''
        if test (count $argv) -gt 0
            zellij attach $argv[1] 2>/dev/null; or zellij -s $argv[1]
        else if zellij list-sessions 2>/dev/null
            set session (zellij list-sessions | gum choose);
            or return (error "You must pick a session!")
            zellij attach "$session"
        else
            zellij -s main
        end
      '';
    };
  };
}
