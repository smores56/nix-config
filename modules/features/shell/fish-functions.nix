_: {
  programs.fish.functions = {
    error = {
      description = "Print error to stderr";
      body = ''
        echo (tput setaf 1)"error: $argv"(tput sgr0) 1>&2
        return 1
      '';
    };
    tailscale-hosts = {
      description = "List all tailscale hosts";
      body = ''
        tailscale status --json | jq ".Peer | to_entries[] | .value.HostName" -r
      '';
    };
    __auto_zellij_update_tabname = {
      onVariable = "PWD";
      description = "Update zellij tab name to git root dir or dir name on dir change";
      body = ''
        if set -q ZELLIJ
            set current_dir $PWD
            if test $current_dir = $HOME
                set tab_name "~"
            else
                set tab_name (basename $current_dir)
            end

            if fish_git_prompt >/dev/null
                set git_root (git rev-parse --show-superproject-working-tree)
                if test -z $git_root
                    set git_root (git rev-parse --show-toplevel)
                end

                if test (string lower "$git_root") != (string lower "$current_dir")
                    set tab_name (basename $git_root)/(basename $current_dir)
                end
            end

            nohup zellij action rename-tab "$tab_name" >/dev/null 2>&1
        end
      '';
    };
  };
}
