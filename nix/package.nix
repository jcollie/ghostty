{
  lib,
  stdenv,
  bzip2,
  callPackage,
  expat,
  fontconfig,
  freetype,
  harfbuzz,
  libpng,
  oniguruma,
  zlib,
  libGL,
  libX11,
  libXcursor,
  libXi,
  libXrandr,
  glib,
  gtk4,
  libadwaita,
  gst_all_1,
  wrapGAppsHook4,
  gsettings-desktop-schemas,
  git,
  glslang,
  ncurses,
  pkg-config,
  zig_0_13,
  pandoc,
  revision ? "dirty",
  optimize ? "Debug",
  x11 ? true,
}: let
  version = "1.0.2";
  # The Zig hook has no way to select the release type without actual
  # overriding of the default flags.
  #
  # TODO: Once
  # https://github.com/ziglang/zig/issues/14281#issuecomment-1624220653 is
  # ultimately acted on and has made its way to a nixpkgs implementation, this
  # can probably be removed in favor of that.
  zig_hook = zig_0_13.hook.overrideAttrs {
    zig_default_flags = "-Dcpu=baseline -Doptimize=${optimize} --color off";
  };

  deps = callPackage ../build.zig.zon.nix {name = "ghostty-cache-${version}";};

  # We limit source like this to try and reduce the amount of rebuilds as possible
  # thus we only provide the source that is needed for the build
  #
  # NOTE: as of the current moment only linux files are provided,
  # since darwin support is not finished
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.intersection (lib.fileset.fromSource (lib.sources.cleanSource ../.)) (
      lib.fileset.unions [
        ../dist/linux
        ../conformance
        ../images
        ../include
        ../media
        ../pkg
        ../src
        ../vendor
        ../build.zig
        ../build.zig.zon
        ../build.zig.zon.nix
      ]
    );
  };
in
  stdenv.mkDerivation (finalAttrs: {
    pname = "ghostty";
    inherit src version;

    nativeBuildInputs = [
      git
      ncurses
      pandoc
      pkg-config
      zig_hook
      wrapGAppsHook4
    ];

    buildInputs =
      [
        libGL
      ]
      ++ lib.optionals stdenv.hostPlatform.isLinux [
        bzip2
        expat
        fontconfig
        freetype
        harfbuzz
        libpng
        oniguruma
        zlib

        libadwaita
        gtk4
        glib
        gst_all_1.gstreamer
        gst_all_1.gst-plugins-base
        gst_all_1.gst-plugins-good

        gsettings-desktop-schemas
      ]
      ++ lib.optionals x11 [
        libX11
        libXcursor
        libXi
        libXrandr
      ];

    dontPatch = true;
    dontConfigure = true;

    zigBuildFlags =
      [
        "--system"
        "${deps}"
        "-Dversion-string=${finalAttrs.version}-${revision}-nix"
        "-Dgtk-x11=${lib.boolToString x11}"
      ]
      ++ lib.mapAttrsToList (name: package: "-fsys=${name} --search-prefix ${lib.getLib package}") {
        inherit fontconfig glslang;
      };

    outputs = [
      "out"
      "terminfo"
      "shell_integration"
      "vim"
    ];

    postInstall = ''
      terminfo_src=${
        if stdenv.hostPlatform.isDarwin
        then ''"$out/Applications/Ghostty.app/Contents/Resources/terminfo"''
        else "$out/share/terminfo"
      }

      mkdir -p "$out/nix-support"

      sed -i -e "s@^Exec=.*ghostty@Exec=$out/bin/ghostty@" $out/share/applications/com.mitchellh.ghostty.desktop
      sed -i -e "s@^TryExec=.*ghostty@TryExec=$out/bin/ghostty@" $out/share/applications/com.mitchellh.ghostty.desktop
      sed -i -e "s@^Exec=.*ghostty@Exec=$out/bin/ghostty@" $out/share/dbus-1/services/com.mitchellh.ghostty.service
      sed -i -e "s@^ExecStart=.*ghostty@ExecStart=$out/bin/ghostty@" $out/lib/systemd/user/com.mitchellh.ghostty.service

      mkdir -p "$terminfo/share"
      mv "$terminfo_src" "$terminfo/share/terminfo"
      ln -sf "$terminfo/share/terminfo" "$terminfo_src"
      echo "$terminfo" >> "$out/nix-support/propagated-user-env-packages"

      mkdir -p "$shell_integration"
      mv "$out/share/ghostty/shell-integration" "$shell_integration/shell-integration"
      ln -sf "$shell_integration/shell-integration" "$out/share/ghostty/shell-integration"
      echo "$shell_integration" >> "$out/nix-support/propagated-user-env-packages"

      mv $out/share/vim/vimfiles "$vim"
      ln -sf "$vim" "$out/share/vim/vimfiles"
      echo "$vim" >> "$out/nix-support/propagated-user-env-packages"

      echo "gst_all_1.gstreamer" >> "$out/nix-support/propagated-user-env-packages"
      echo "gst_all_1.gst-plugins-base" >> "$out/nix-support/propagated-user-env-packages"
      echo "gst_all_1.gst-plugins-good" >> "$out/nix-support/propagated-user-env-packages"
    '';

    meta = {
      homepage = "https://ghostty.org";
      license = lib.licenses.mit;
      platforms = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      mainProgram = "ghostty";
    };
  })
