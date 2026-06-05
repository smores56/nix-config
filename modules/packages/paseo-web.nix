{
  lib,
  buildNpmPackage,
  nodejs_22,
  python3,
  paseoSrc,
  paseoVersion,
  npmDeps,
}:

buildNpmPackage {
  pname = "paseo-web";
  inherit npmDeps;

  version = paseoVersion;

  src = lib.cleanSourceWith {
    src = paseoSrc;
    filter =
      path: type:
      let
        baseName = builtins.baseNameOf path;
        relPath = lib.removePrefix (toString paseoSrc) path;
      in
      !(lib.hasPrefix "/packages/app/android" relPath)
      && !(lib.hasPrefix "/packages/app/ios" relPath)
      && !(lib.hasPrefix "/packages/desktop" relPath)
      && !(lib.hasPrefix "/packages/website" relPath)
      && !(lib.hasSuffix ".test.ts" baseName)
      && !(lib.hasSuffix ".e2e.test.ts" baseName)
      && baseName != "node_modules"
      && baseName != ".git"
      && baseName != ".paseo"
      && baseName != ".DS_Store"
      && baseName != "release";
  };

  nodejs = nodejs_22;

  npmRebuildFlags = [ "--ignore-scripts" ];

  nativeBuildInputs = [ python3 ];

  dontNpmBuild = true;

  env = {
    EXPO_NO_TELEMETRY = "1";
    CI = "1";
    EXPO_PUBLIC_LOCAL_DAEMON = "paseo.sammohr.dev:443";
  };

  buildPhase = ''
    runHook preBuild

    npm run build:daemon
    npm run build --workspace=@getpaseo/expo-two-way-audio

    ( cd packages/app && npx expo export --platform web )

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out
    cp -r packages/app/dist/* $out/

    # Force TLS for daemon WS connections from the web SPA.
    # Browser blocks ws:// from https://, and Cloudflare edge only accepts wss://.
    find "$out" -name '*.js' -exec sed -i \
      -e 's/ws:\/\/paseo\.sammohr\.dev:443\/ws/wss:\/\/paseo.sammohr.dev:443\/ws/g' \
      {} +

    runHook postInstall
  '';

  meta = {
    description = "Paseo web app (Expo SPA)";
    homepage = "https://github.com/getpaseo/paseo";
    license = lib.licenses.agpl3Plus;
    platforms = lib.platforms.linux;
  };
}
