# The agent's book shelf. `fanficfare-download` writes an EPUB under
# ~/wip/books (a read-write agent-VM share, completed by rename), and this unit
# copies each finished file into the library share, where OPDShelf treats it as
# a book: the folder is the catalog, so there is nothing to import or index.
#
# The agent has no path into /var/lib/data, which is deliberate: the shell only
# ever queues files, and the host decides what enters the library.
{ config, pkgs, ... }:
let
  user = "smores";
  home = config.users.users.${user}.home;
  shelf = "${home}/wip/books";
  library = "/var/lib/data/books";
  imported = "${library}/imported";

  shelve = pkgs.writeShellApplication {
    name = "books-shelve";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
    ];
    text = ''
      set -euo pipefail

      install -d -m 0775 -o ${user} -g users ${imported}

      shopt -s nullglob
      for src in ${shelf}/*.epub; do
        name=$(basename "$src")
        tmp=${imported}/.''${name}.tmp
        # Copy first, then rename: the library never sees a partial file, and a
        # failure leaves the source in place to retry.
        cp --preserve=mode,timestamps "$src" "$tmp"
        chown ${user}:users "$tmp"
        mv "$tmp" "${imported}/$name"
        rm -f "$src"
        printf 'shelved %s\n' "$name"
      done
    '';
  };
in
{
  systemd.services.books-shelf = {
    description = "Move agent-queued EPUBs into the books library";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${shelve}/bin/books-shelve";
      # The mover reads the shelf and writes the library, and needs root for the
      # chown that maps the files onto the share's owner (guest uid 1000).
      ProtectSystem = "strict";
      ReadWritePaths = [
        library
        shelf
      ];
      PrivateTmp = true;
      NoNewPrivileges = true;
    };
  };

  systemd.paths.books-shelf = {
    description = "Watch the agent book shelf";
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathExistsGlob = "${shelf}/*.epub";
      Unit = "books-shelf.service";
    };
  };
}
