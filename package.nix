{
  lib,
  stdenv,
  cmake,
  src ? ./.,
}:

stdenv.mkDerivation {
  pname = "ripwire";
  version = "0.6.1";

  inherit src;

  nativeBuildInputs = [ cmake ];

  # All deps are vendored in-tree (tree-sitter runtime + grammars incl. nix, gtl,
  # phmap, doctest); disconnected configure is the upstream-supported offline mode.
  cmakeFlags = [ "-DFETCHCONTENT_FULLY_DISCONNECTED=ON" ];

  # nixpkgs' cmake hook sets CMAKE_BUILD_TYPE=Release (its cmakeBuildType
  # default): NDEBUG compiles the DISCLOSE() trace out — which is CORRECT for
  # a build meant to be USED (upstream's Release/CI leg); gate work runs in
  # the dev tree with a plain configure, never against this artifact.

  # The gate suite is an interactive python harness (test/pargates.py), not
  # wired into cmake — doCheck stays off; the installCheck below is a smoke,
  # not a substitute.
  doCheck = false;

  # Component-scoped install by hand instead of `make install`: the global
  # install() also runs the vendored tree-sitter subproject's own rules
  # (headers/pkgconfig/static lib), and ripwire only needs bin + share.
  # wrap.h resolves skills at <exeDir>/../share/ripwire/skills — keep the layout.
  # Phases may run with cwd inside cmakeBuildDir, so anchor on the source root.
  dontUseCmakeInstall = true;
  installPhase = ''
    runHook preInstall
    root=$NIX_BUILD_TOP/$sourceRoot
    install -Dm755 "$root/build/ripwire" $out/bin/ripwire
    mkdir -p $out/share/ripwire
    cp -r "$root/skills" "$root/hooks" $out/share/ripwire/
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    $out/bin/ripwire --version
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    cat > "$work/mod.nix" <<'EOF'
    { lib }:
    {
      networking.hostName = "sample";
      imports = [ ./plain.nix ];
    }
    EOF
    echo '{ }: ' > "$work/plain.nix"
    $out/bin/ripwire "$work" | grep -q 'hostName'
    echo "ripwire installCheck: Nix scan smoke OK"
    runHook postInstallCheck
  '';

  meta = {
    description = "Ranked, deterministic codebase maps for coding agents — the ripgrep of AI context";
    longDescription = ''
      Parses a codebase, ranks symbols by Personalized PageRank, and streams a
      deterministic minified XML map to stdout. Zero runtime deps. This build
      includes the Nix grammar lane (.nix definitions, calls, and file
      dependencies).
    '';
    homepage = "https://github.com/redhat-et/ripwire";
    license = lib.licenses.asl20;
    mainProgram = "ripwire";
    platforms = lib.platforms.unix;
  };
}
