# calibre + the FanFicFare CLI (headless story downloads). The library itself is
# served by the cluster at https://opds.sammohr.dev (docs/data-migration.md in
# smores56/homelabs-platform); the host keeps only the CLI so a story can be
# built and its metadata read by hand.
#
# Agents write the library directly: nanobot mounts /var/lib/data/books as its
# `nanobot-books` claim (#635), so there is no queue and no import step, and
# OPDShelf reads the folder tree as the catalog. The legacy books-shelf unit
# still watches ~/wip/books until #636 removes it; nothing writes that path.
#
# Upstream: https://github.com/JimmXinu/FanFicFare
{ pkgs, ... }:
{
  home.packages = [
    pkgs.calibre
    pkgs.fanficfare
  ];
}
