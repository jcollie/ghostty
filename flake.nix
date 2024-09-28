{
  description = "👻";

  inputs = {
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixpkgs-unstable";

    # We want to stay as up to date as possible but need to be careful that the
    # glibc versions used by our dependencies from Nix are compatible with the
    # system glibc that the user is building for.
    nixpkgs-stable.url = "github:nixos/nixpkgs/release-24.11";
    flake-utils.url = "github:numtide/flake-utils";

    # Used for shell.nix
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };

    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs-stable";
        flake-utils.follows = "flake-utils";
        flake-compat.follows = "";
      };
    };

    zig2nix = {
      url = "github:jcollie/zig2nix?ref=672971b5b6911de21446ad4fc76dee677922eda0";
      inputs = {
        nixpkgs.follows = "nixpkgs-stable";
        flake-utils.follows = "flake-utils";
      };
    };
  };

  outputs = {
    self,
    nixpkgs-stable,
    nixpkgs-unstable,
    zig,
    zig2nix,
    ...
  }:
    builtins.foldl' nixpkgs-stable.lib.attrsets.recursiveUpdate {} (
      builtins.map
      (
        system: let
          pkgs-stable = import nixpkgs-stable {
            inherit system;
          };
          pkgs-unstable = import nixpkgs-unstable {
            inherit system;
          };
        in {
          devShells.${system} = {
            default = self.devShells.${system}.stable;
            stable = pkgs-stable.callPackage ./nix/devShell.nix {
              # zig_0_13 = zig.packages.${system}."0.13.0";
              zig2nix = zig2nix;
              wraptest = pkgs-unstable.callPackage ./nix/wraptest.nix {};
            };
            unstable = pkgs-unstable.callPackage ./nix/devShell.nix {
              # zig_0_13 = zig.packages.${system}."0.13.0";
              zig2nix = zig2nix;
              wraptest = pkgs-unstable.callPackage ./nix/wraptest.nix {};
            };
          };

          packages.${system} = let
            mkArgs = optimize: {
              inherit optimize;

              revision = self.shortRev or self.dirtyShortRev or "dirty";
            };
          in {
            deps = pkgs-stable.callPackage ./build.zig.zon.nix {};
            default = self.packages.${system}.ghostty;
            ghostty = self.packages.${system}.ghostty-releasefast;
            ghostty-debug = self.packages.${system}.ghostty-stable-debug;
            ghostty-releasesafe = self.packages.${system}.ghostty-stable-releasesafe;
            ghostty-releasefast = self.packages.${system}.ghostty-stable-releasefast;
            ghostty-stable-debug = pkgs-stable.callPackage ./nix/package.nix (mkArgs "Debug");
            ghostty-stable-releasesafe = pkgs-stable.callPackage ./nix/package.nix (mkArgs "ReleaseSafe");
            ghostty-stable-releasefast = pkgs-stable.callPackage ./nix/package.nix (mkArgs "ReleaseFast");
            ghostty-unstable-debug = pkgs-unstable.callPackage ./nix/package.nix (mkArgs "Debug");
            ghostty-unstable-releasesafe = pkgs-unstable.callPackage ./nix/package.nix (mkArgs "ReleaseSafe");
            ghostty-unstable-releasefast = pkgs-unstable.callPackage ./nix/package.nix (mkArgs "ReleaseFast");
          };

          formatter.${system} = pkgs-stable.alejandra;

          apps.${system} = let
            runVM = (
              module: let
                vm = import ./nix/vm/create.nix {
                  inherit system module;
                  nixpkgs = nixpkgs-stable;
                  overlay = self.overlays.debug;
                };
                program = pkgs-stable.writeShellScript "run-ghostty-vm" ''
                  SHARED_DIR=$(pwd)
                  export SHARED_DIR

                  ${pkgs-stable.lib.getExe vm.config.system.build.vm} "$@"
                '';
              in {
                type = "app";
                program = "${program}";
              }
            );
          in {
            wayland-cinnamon = runVM ./nix/vm/wayland-cinnamon.nix;
            wayland-gnome = runVM ./nix/vm/wayland-gnome.nix;
            wayland-plasma6 = runVM ./nix/vm/wayland-plasma6.nix;
            x11-cinnamon = runVM ./nix/vm/x11-cinnamon.nix;
            x11-gnome = runVM ./nix/vm/x11-gnome.nix;
            x11-plasma6 = runVM ./nix/vm/x11-plasma6.nix;
            x11-xfce = runVM ./nix/vm/x11-xfce.nix;
          };
        }
        # Our supported systems are the same supported systems as the Zig binaries.
      ) (builtins.attrNames zig.packages)
    )
    // {
      overlays = {
        default = self.overlays.releasefast;
        releasefast = final: prev: {
          ghostty = self.packages.${prev.system}.ghostty-releasefast;
        };
        debug = final: prev: {
          ghostty = self.packages.${prev.system}.ghostty-debug;
        };
      };
      create-vm = import ./nix/vm/create.nix;
      create-cinnamon-vm = import ./nix/vm/create-cinnamon.nix;
      create-gnome-vm = import ./nix/vm/create-gnome.nix;
      create-plasma6-vm = import ./nix/vm/create-plasma6.nix;
      create-xfce-vm = import ./nix/vm/create-xfce.nix;
    };

  nixConfig = {
    extra-substituters = ["https://ghostty.cachix.org"];
    extra-trusted-public-keys = ["ghostty.cachix.org-1:QB389yTa6gTyneehvqG58y0WnHjQOqgnA+wBnpWWxns="];
  };
}
