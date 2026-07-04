{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles.smolvm;

  # Short-lived per-repo dev VM, distinct from the persistent agent VM in
  # default.nix. Tooling inside is managed by mise (per-repo .tool-versions),
  # not the shared bin mount. Created on demand from the repo root.
  smolvm = "${pkgs.smolvm}/bin/smolvm";
  jqBin = "${lib.getBin pkgs.jq}/bin/jq";
  coreutilsBin = "${lib.getBin pkgs.coreutils}/bin";
  image = "cgr.dev/chainguard/wolfi-base";

  devLauncher = pkgs.writeShellScriptBin "smolvm-enter" ''
    set -euo pipefail

    # Find repo root by walking up for mise.toml
    dir="$PWD"
    repo_root=""
    while [ "$dir" != "/" ]; do
      if [ -f "$dir/mise.toml" ] || [ -f "$dir/.mise.toml" ] || [ -f "$dir/.tool-versions" ]; then
        repo_root="$dir"
        break
      fi
      dir="$(${coreutilsBin}/dirname "$dir")"
    done

    if [ -z "$repo_root" ]; then
      echo "smolvm-enter: no mise.toml found in $PWD or any parent" >&2
      exit 1
    fi

    # Derive stable VM name from repo path
    hash=$(echo -n "$repo_root" | ${coreutilsBin}/sha256sum | ${coreutilsBin}/cut -c1-12)
    base=$(${coreutilsBin}/basename "$repo_root")
    vm_name="dev-''${base}-''${hash}"

    vm_state="absent"
    if ${smolvm} machine status --name "$vm_name" --json >/dev/null 2>&1; then
      vm_state="$(${smolvm} machine status --name "$vm_name" --json 2>/dev/null | ${jqBin} -r '.state')"
    fi

    if [ "$vm_state" = "running" ]; then
      :
    elif [ "$vm_state" = "stopped" ] || [ "$vm_state" = "created" ]; then
      echo "smolvm: starting existing VM ''${vm_name}..."
      ${smolvm} machine start --name "$vm_name"
    else
      echo "smolvm: creating VM ''${vm_name} from ''${image}..."
      echo "smolvm: repo: ''${repo_root}"
      ${smolvm} machine create \
        --image "$image" \
        --net \
        --volume "''${repo_root}:/repo" \
        --workdir /repo \
        --cpus 4 \
        --mem 8192 \
        --ssh-agent \
        --init 'apk add --no-cache curl ca-certificates libstdc++ && curl -sSf https://mise.run | MISE_QUIET=1 sh && export PATH="$HOME/.local/bin:$PATH" && cd /repo && mise trust && mise install' \
        --env BUN_INSTALL=/root/.bun \
        --env MISE_DATA_DIR=/root/.local/share/mise \
        "$vm_name"

      echo "smolvm: starting VM (first boot installs tools, this may take a minute)..."
      ${smolvm} machine start --name "$vm_name"
    fi

    echo "smolvm: entering VM ''${vm_name}..."
    echo "smolvm: tools are managed by mise — run 'mise exec -- <cmd>' or 'eval \$(mise activate bash)'"
    exec ${smolvm} machine shell --name "$vm_name"
  '';
in
{
  config = lib.mkIf cfg.enable {
    home.packages = [ devLauncher ];
  };
}
