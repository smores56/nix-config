{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;

  goodix53x5-src = pkgs.fetchFromGitHub {
    owner = "AndyHazz";
    repo = "goodix53x5-libfprint";
    rev = "399057b6ae97b80135e58b96e569f0f3a10532f5";
    hash = "sha256-wJV4dz2DxpfPUIHPjHcgv8tE3pLHBdhjFOd1E7F3LT4=";
  };

  libfprint-goodix53x5 = pkgs.libfprint.overrideAttrs (old: {
    doCheck = false;
    doInstallCheck = false;
    buildInputs = old.buildInputs ++ (with pkgs; [
      opencv
      openssl
    ]);
    nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.pkg-config ];
    postPatch = (old.postPatch or "") + ''
      mkdir -p libfprint/drivers/goodix53x5
      cp ${goodix53x5-src}/drivers/goodix53x5/* libfprint/drivers/goodix53x5/
      mkdir -p libfprint/sigfm
      cp ${goodix53x5-src}/sigfm/* libfprint/sigfm/
      patch -p1 < ${goodix53x5-src}/meson-integration.patch
      substituteInPlace libfprint/meson.build \
        --replace-fail "/usr/include/opencv4" "${pkgs.opencv}/include/opencv4"
      substituteInPlace meson.build \
        --replace-fail "subdir('tests')" ""
    '';
  });

  fprintd-goodix53x5 = pkgs.fprintd.override {
    libfprint = libfprint-goodix53x5;
  };
in
{
  services.fprintd = lib.mkIf cfg.fingerprint {
    enable = true;
    package = fprintd-goodix53x5;
  };

  services.udev.extraRules = lib.mkIf cfg.fingerprint ''
    ACTION=="bind", SUBSYSTEM=="usb", DRIVER=="cdc_acm", ATTRS{idVendor}=="27c6", ATTRS{idProduct}=="5385", RUN+="/bin/sh -c 'echo %k > /sys/bus/usb/drivers/cdc_acm/unbind 2>/dev/null || true'"
  '';

  security.pam.services.noctalia-shell =
    if cfg.fingerprint then
      { fprintAuth = true; }
    else
      {
        text = ''
          auth include login
        '';
      };
}
