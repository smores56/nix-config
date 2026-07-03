{
  pkgs,
  ...
}:

let
  # Tier-1 tools: system utilities that don't self-update. Pre-baked into
  # the rootfs so they're available immediately on VM boot without apt-get
  # or curl|sh. All built by Nix for the guest's Linux arch.
  #
  # Tier-2 tools (bun, omp, maki) have self-update mechanisms that fight
  # Nix's immutability — those stay on their existing installer flow in
  # the persistent overlay, installed by the launcher's provisionScript.
  rootfsTools = [
    pkgs.git
    pkgs.gh
    pkgs.openssh
    pkgs.python3
    pkgs.curl
    pkgs.unzip
    pkgs.gnutar
    pkgs.gzip
    pkgs.bash
    pkgs.coreutils
    pkgs.gnugrep
    pkgs.gnused
    pkgs.gawk
    pkgs.findutils
    pkgs.diffutils
    pkgs.patch
    pkgs.which
    pkgs.cacert
  ];

  # A buildEnv profile: a /nix/store/...-env directory with bin/, etc.
  # Symlinks into the store for each package.
  profile = pkgs.buildEnv {
    name = "smolvm-agent-rootfs-profile";
    paths = rootfsTools;
    pathsToLink = [
      "/bin"
      "/share"
    ];
    ignoreCollisions = true;
  };

  # closureInfo gives the full transitive list of /nix/store paths needed
  # by the profile. We copy these into the rootfs so dynamic linking works
  # inside the guest (ELF interpreter paths resolve).
  closure = pkgs.closureInfo { rootPaths = [ profile ]; };

  passwd = pkgs.writeText "passwd" ''
    root:x:0:0:root:/root:/bin/bash
  '';
  group = pkgs.writeText "group" ''
    root:x:0:
  '';
  nsswitch = pkgs.writeText "nsswitch.conf" ''
    passwd:    files
    group:     files
    shadow:    files
    hosts:     files dns
    networks:  files dns
  '';
  profileScript = pkgs.writeText "nix-bin.sh" ''
    export PATH="/root/.bun/bin:/mnt/smolvm-shared/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin"
  '';
in

pkgs.runCommand "smolvm-agent-rootfs" { } ''
  set -euo pipefail
  rootfs="$out"
  mkdir -p "$rootfs"

  # 1. Copy the full nix store closure so ELF interp paths resolve.
  mkdir -p "$rootfs/nix/store"
  while IFS= read -r p; do
    [ -d "$p" ] || continue
    dest="$rootfs$p"
    [ -e "$dest" ] || cp -r "$p" "$dest"
  done < "${closure}/store-paths"

  # 2. Profile bin symlinks.
  mkdir -p "$rootfs/nix/var/nix/profiles/default"
  cp -r "${profile}"/* "$rootfs/nix/var/nix/profiles/default/"

  # 3. FHS scaffolding: smolvm's is_rootfs_dir checks for bin/usr/etc/sbin.
  # FHS dynamic linker path so glibc-linked binaries (bun, etc.) resolve.
  mkdir -p "$rootfs/lib64" "$rootfs/lib"
  ln -sf "${pkgs.glibc}/lib/ld-linux-x86-64.so.2" "$rootfs/lib64/ld-linux-x86-64.so.2"
  ln -sf "${pkgs.glibc}/lib/ld-linux-aarch64.so.1" "$rootfs/lib/ld-linux-aarch64.so.1"
  mkdir -p "$rootfs/bin" "$rootfs/usr/bin" "$rootfs/usr/sbin" "$rootfs/sbin"
  mkdir -p "$rootfs/etc" "$rootfs/root" "$rootfs/tmp" "$rootfs/var"
  mkdir -p "$rootfs/root/.local/bin" "$rootfs/root/.bun/bin"
  mkdir -p "$rootfs/dev" "$rootfs/proc" "$rootfs/sys"

  # /bin/sh → bash (crun OCI runtime requires /bin/sh).
  ln -sf "${profile}/bin/bash" "$rootfs/bin/sh"
  ln -sf "${profile}/bin/bash" "$rootfs/bin/bash"

  # Common utilities in /usr/bin for #!/usr/bin/env shebangs.
  for cmd in env cat ls cp mv rm mkdir rmdir echo printf ln touch stat \
             grep sed awk find which diff patch tar gzip gunzip; do
    [ -e "${profile}/bin/$cmd" ] && ln -sf "${profile}/bin/$cmd" "$rootfs/usr/bin/$cmd"
  done

  # 4. /etc
  cp "${passwd}" "$rootfs/etc/passwd"
  cp "${group}" "$rootfs/etc/group"
  cp "${nsswitch}" "$rootfs/etc/nsswitch.conf"
  mkdir -p "$rootfs/etc/ssl/certs" "$rootfs/etc/profile.d"
  cp -fL "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" "$rootfs/etc/ssl/certs/ca-certificates.crt"
  cp -fL "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" "$rootfs/etc/ssl/certs/ca-bundle.crt"
  cp "${profileScript}" "$rootfs/etc/profile.d/nix-bin.sh"
  echo "nameserver 1.1.1.1" > "$rootfs/etc/resolv.conf"

  chmod 0755 "$rootfs" "$rootfs/bin" "$rootfs/usr" "$rootfs/etc" "$rootfs/root"
''
