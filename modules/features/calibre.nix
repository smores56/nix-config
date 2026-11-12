# calibre + the FanFicFare CLI (headless story downloads). The library itself is
# served by the cluster at https://opds.sammohr.dev (docs/data-migration.md in
# smores56/homelabs-platform); the host keeps only the CLI so agents can read
# metadata out of a file and `fanficfare-download` can build one.
#
# Agents deliver books by writing an EPUB to `~/wip/books`: the books-shelf unit
# on smortress moves it into the library share, which OPDShelf treats as the
# catalog. No content server, no metadata database, no share between guest and
# library.
#
# Upstream: https://github.com/JimmXinu/FanFicFare
{ pkgs, ... }:
{
  home.packages = [
    pkgs.calibre
    pkgs.fanficfare
  ];
}
