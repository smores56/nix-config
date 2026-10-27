{ pkgs }:

assert pkgs.lib.versionAtLeast pkgs.go.version "1.25";

pkgs.buildGoModule rec {
  pname = "slack-mcp-server";
  version = "1.3.0";

  src = pkgs.fetchFromGitHub {
    owner = "korotovsky";
    repo = "slack-mcp-server";
    rev = "a079b3cd4d5836d791c942a9fc107987e7865b37";
    hash = "sha256-I4f6yKV0BXtaxnqi/XNID+Pwl2mWjSqxIHhb07U7sc4=";
  };

  vendorHash = "sha256-+uQRODO9oL8mGKBmdghTxE6R9Fz+3GJFVTi17306gT8=";

  patches = [
    ./backend.patch
    ./backend-tests.patch
  ];

  subPackages = [ "cmd/slack-mcp-server" ];

  env = {
    CGO_ENABLED = 0;
    GOTOOLCHAIN = "local";
  };

  ldflags = [
    "-s"
    "-w"
    "-X github.com/korotovsky/slack-mcp-server/pkg/version.Version=v${version}"
    "-X github.com/korotovsky/slack-mcp-server/pkg/version.CommitHash=${src.rev}"
  ];

  checkPhase = ''
    runHook preCheck
    go test -count=1 -timeout=60s -v ./pkg/provider
    runHook postCheck
  '';

  meta = {
    description = "Slack MCP server with in-memory-only user and channel caches";
    homepage = "https://github.com/korotovsky/slack-mcp-server";
    license = pkgs.lib.licenses.mit;
    mainProgram = "slack-mcp-server";
    platforms = pkgs.lib.platforms.unix;
  };
}
