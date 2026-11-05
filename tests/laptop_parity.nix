# Compares what the user sees on the two laptops and fails on any difference
# `sanctioned` does not explain (and on any entry that no longer differs).
# Desktop bindings are covered by shared_desktop_bindings.nix.
{
  lib,
  work,
  pro,
  sanctioned,
}:
let
  # Store hashes, package versions and the platform's home directory are not differences.
  normalize =
    c: s:
    lib.replaceStrings [ c.home.homeDirectory ] [ "~" ] (
      lib.concatStrings (
        map (p: if builtins.isString p then p else "/nix/store/${lib.head p}") (
          builtins.split "/nix/store/[a-z0-9]{32}-([A-Za-z0-9_+]+(-[A-Za-z_+][A-Za-z0-9_+]*)*)(-[0-9][^/ ]*)?" (
            builtins.unsafeDiscardStringContext s
          )
        )
      )
    );

  presence = names: lib.genAttrs (lib.unique names) (_: "present");
  category = name: items: lib.mapAttrs' (k: v: lib.nameValuePair "${name}.${k}" v) items;

  surface =
    c: shell:
    let
      show = v: normalize c (if builtins.isString v then v else builtins.toJSON v);
      leaves =
        prefix: v:
        if builtins.isAttrs v && !(v ? type && v.type == "derivation") then
          lib.concatMapAttrs (k: leaves "${prefix}${lib.optionalString (prefix != "") "."}${k}") v
        else
          { ${prefix} = show v; };
    in
    {
      shell =
        category "abbrs" c.user.shellAbbrs
        // category "aliases" c.programs.${shell}.shellAliases
        // category "env" (lib.mapAttrs (_: show) c.home.sessionVariables)
        // category "path" (presence (map (normalize c) c.home.sessionPath));
      # Matches are DAG entries; the block lives under .data.
      ssh = leaves "" (lib.mapAttrs (_: e: e.data or e) c.programs.ssh.settings);
      # Values hold store paths and host-specific keys, so git compares keys only.
      git = lib.mapAttrs (_: _: "set") (leaves "" c.programs.git.settings);
      packages = presence (map lib.getName c.home.packages);
      activation = presence (lib.attrNames c.home.activation);
      # A systemd timer and its service are one job, like one launchd agent.
      services = presence (
        lib.attrNames c.systemd.user.services
        ++ lib.attrNames c.systemd.user.timers
        ++ lib.attrNames (lib.filterAttrs (_: a: a.enable) c.launchd.agents)
      );
      # Removed modules throw on `enable`; they are not enabled.
      programs = presence (
        lib.attrNames (
          lib.filterAttrs (
            _: v:
            let
              on = builtins.tryEval (builtins.isAttrs v && (v.enable or false) == true);
            in
            on.success && on.value
          ) c.programs
        )
      );
    };

  w = surface work "zsh";
  p = surface pro "fish";

  flat = s: lib.concatMapAttrs (cat: lib.mapAttrs' (k: v: lib.nameValuePair "${cat}/${k}" v)) s;
  wf = flat w;
  pf = flat p;

  differing = lib.filter (k: (wf.${k} or null) != (pf.${k} or null)) (lib.attrNames (wf // pf));
  allowed = flat (lib.mapAttrs (_: lib.mapAttrs (_: _: null)) sanctioned);
  reasons = flat sanctioned;

  render = v: if v == null then "<absent>" else lib.strings.substring 0 60 v;
  line = k: "  ${k}: work=${render (wf.${k} or null)} pro=${render (pf.${k} or null)}";

  unsanctioned = lib.filter (k: !(allowed ? ${k})) differing;
  stale = lib.filter (k: !(lib.elem k differing)) (lib.attrNames allowed);
  badReason = lib.filter (k: builtins.match "(inherent|work-policy): .+" reasons.${k} == null) (
    lib.attrNames reasons
  );

  section =
    title: items: lib.optional (items != [ ]) (lib.concatStringsSep "\n" ([ title ] ++ items));
  problems =
    section "Unsanctioned differences (fix them, or add to tests/laptop-parity-sanctioned.nix):" (
      map line unsanctioned
    )
    ++ section "Stale sanctioned entries (no longer differ; delete them):" (map (k: "  ${k}") stale)
    ++ section "Reasons must start with `inherent: ` or `work-policy: `:" (map (k: "  ${k}") badReason);
in
if problems == [ ] then "ok" else throw ("\n" + lib.concatStringsSep "\n" problems)
