{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;
  inherit (cfg.work) flatRepos githubOwnerGlob toolShell;
  enabled = cfg.workHost && flatRepos != null;

  links = import ../lib/work-repo-links.nix { inherit pkgs; };
  linkArgs = lib.escapeShellArgs (
    [
      flatRepos.dir
      "${cfg.codeRoot}/github.com"
    ]
    ++ flatRepos.orgs
  );
  # This host's layout baked in, so `work-repo-links --migrate` needs no args.
  hostLinks = pkgs.writeShellScriptBin "work-repo-links" ''
    if [ "''${1-}" = --migrate ]; then
      exec ${lib.getExe links} --migrate ${linkArgs}
    fi
    exec ${lib.getExe links} ${linkArgs}
  '';

  # git wildmatch (as used by the work includes) to a case-folded regex;
  # owner globs only use * and ?.
  globRegex =
    glob:
    lib.concatMapStrings (
      c:
      if c == "*" then
        ".*"
      else if c == "?" then
        "."
      else
        lib.escapeRegex c
    ) (lib.stringToCharacters (lib.toLower glob));
  outsideGlob = lib.filter (
    org: builtins.match (globRegex githubOwnerGlob) (lib.toLower org) == null
  ) (if flatRepos == null then [ ] else flatRepos.orgs);
in
lib.mkIf enabled {
  assertions = [
    {
      assertion = lib.hasPrefix "/" flatRepos.dir && !(lib.hasSuffix "/" flatRepos.dir);
      message = "dotfiles.work.flatRepos.dir must be an absolute path without a trailing slash: ${flatRepos.dir}";
    }
    {
      # A linked org outside the glob would sit in the work folder but commit
      # with the personal identity.
      assertion = outsideGlob == [ ];
      message = "dotfiles.work.flatRepos.orgs not matched by githubOwnerGlob ${githubOwnerGlob}: ${lib.concatStringsSep ", " outsideGlob}";
    }
  ];

  # Employer tooling sees one flat folder while every checkout stays
  # reachable at <codeRoot>/github.com/<owner>/<repo>.
  home.activation.workRepoLinks = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${lib.getExe hostLinks}
  '';
  home.packages = [ hostLinks ];

  home.sessionVariables = lib.optionalAttrs (flatRepos.envVar != null) {
    ${flatRepos.envVar} = flatRepos.dir;
  };

  programs.fish = {
    # Employer toolchains often pin Python through a non-Nix pyenv; init it
    # only where one is installed so repo .python-version venvs resolve.
    # --no-rehash keeps shell startup off pyenv's shim lock. With no pyenv
    # global set, bare python3 falls through to the Nix one.
    interactiveShellInit = lib.mkAfter ''
      if type -q pyenv
          pyenv init - --no-rehash fish | source
          if type -q pyenv-virtualenv-init
              pyenv virtualenv-init - fish | source
          end
      end
    '';
    functions = lib.optionalAttrs (toolShell != null) {
      wsh = {
        description = "Open the work tooling's shell (${toolShell}) in ${flatRepos.dir}";
        # Interactive, not login: a login zsh runs macOS path_helper, which
        # moves /usr/bin and Homebrew ahead of the Nix profile.
        body = ''
          pushd ${lib.escapeShellArg flatRepos.dir}; or return
          command ${toolShell} -i $argv
          set -l rc $status
          popd
          return $rc
        '';
      };
    };
  };
}
