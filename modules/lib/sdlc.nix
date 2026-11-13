# The one `sdlc` CLI: the host profile and the agent VM install the same package. It is built
# from upstream `smores56/sdlc`'s pyproject; see `modules/features/ai/sdlc/package.nix` for
# why the source is vendored and how `sync.sh` refreshes it.
{ pkgs }:
import ../features/ai/sdlc/package.nix { inherit pkgs; }
