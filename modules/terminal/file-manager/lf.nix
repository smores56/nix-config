{ pkgs, ... }: {
  home.packages = with pkgs; [
    ctpv
    chafa
    trash-cli
  ];

  programs.lf = {
    enable = true;

    settings = {
      icons = true;
      shell = "${pkgs.bash}/bin/bash";
      shellopts = "-eu";
      ifs = "\\n";
      scrolloff = 10;
    };

    commands = {
      trash = "%trash-put $fx";
      open = ''''${{
        if [ ! -s $f ]; then
            $EDITOR $fx
        else
            test -L $f && f=$(readlink -f $f)
            case $(file --mime-type $f -b) in
                text/*) $EDITOR $fx;;
                *) for f in $fx; do setsid $OPENER $f > /dev/null 2> /dev/null & done;;
            esac
        fi
      }}'';
      extract = ''''${{
        set -f
        case $f in
            *.tar.bz|*.tar.bz2|*.tbz|*.tbz2) tar xjvf $f;;
            *.tar.gz|*.tgz) tar xzvf $f;;
            *.tar.xz|*.txz) tar xJvf $f;;
            *.zip) unzip $f;;
            *.rar) unrar x $f;;
            *.7z) 7z x $f;;
        esac
      }}'';
      tar = ''''${{
        set -f
        mkdir $1
        cp -r $fx $1
        tar czf $1.tar.gz $1
        rm -rf $1
      }}'';
      zip = ''''${{
        set -f
        mkdir $1
        cp -r $fx $1
        zip -r $1.zip $1
        rm -rf $1
      }}'';
    };

    keybindings = {
      "<backspace2>" = "set hidden!";
      "<enter>" = "shell";
      "<delete>" = "trash";
      o = "&mimeopen $f";
      O = "$mimeopen --ask $f";
      a = "push %mkdir<space>";
      t = "push %touch<space>";
    };

    previewer.source = "${pkgs.ctpv}/bin/ctpv";

    extraConfig = ''
      set cleaner ctpvclear
      &ctpv -s $id
      &ctpvquit $id
    '';
  };
}
