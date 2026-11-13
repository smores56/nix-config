# The `sdlc` CLI, built from the pyproject that upstream `smores56/sdlc` ships rather than
# wrapped by hand. Upstream is private: an unauthenticated `fetchFromGitHub`/tarball fetch is
# a 404, and neither CI nor a fresh host holds a GitHub credential, so `src` defaults to the
# pinned vendored copy (`UPSTREAM_REV`, refreshed by `sync.sh`). A host that can reach the
# repo may pass a locked `src`, e.g.
#
#   src = pkgs.fetchgit {
#     url = "ssh://git@github.com/smores56/sdlc";
#     rev = "…";
#     hash = "sha256-…";
#   };
{
  pkgs,
  lib ? pkgs.lib,
  src ? lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./pyproject.toml
      ./sdlc_issues.py
      ./README.md
    ];
  },
}:
pkgs.python3Packages.buildPythonApplication {
  pname = "smores-sdlc";
  version = "0.1.0";
  pyproject = true;
  inherit src;

  build-system = [ pkgs.python3Packages.setuptools ];

  # The CLI shells out to `gh`, `git`, `revdiff` and `tv` from the caller's PATH, so there is
  # nothing to test at build time; `tests/test_sdlc_issues.py` is the vendored upstream suite
  # and runs in the `unit-tests` check.
  doCheck = false;
  pythonImportsCheck = [ "sdlc_issues" ];

  meta = {
    description = "Stateless SDLC CLI over GitHub Issues";
    mainProgram = "sdlc";
  };
}
