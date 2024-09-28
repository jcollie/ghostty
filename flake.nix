{
  description = "👻";

  inputs = {
    nixpkgs-stable.url = "github:nixos/nixpkgs/nixos-24.11";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";

    # Used for shell.nix
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };

    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs-stable";
      };
    };
  };

  outputs = {
    self,
    nixpkgs-stable,
    nixpkgs-unstable,
    zig,
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
              wraptest = pkgs-unstable.callPackage ./nix/wraptest.nix {};
            };
            unstable = pkgs-unstable.callPackage ./nix/devShell.nix {
              # zig_0_13 = zig.packages.${system}."0.13.0";
              wraptest = pkgs-unstable.callPackage ./nix/wraptest.nix {};
            };
          };

          packages.${system} = let
            mkArgs = optimize: {
              inherit optimize;
              revision = self.shortRev or self.dirtyShortRev or "dirty";
            };
          in {
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

          formatter.${system} = pkgs-unstable.alejandra;
        }
      )
      # Our supported systems are the same supported systems as the Zig binaries.
      (builtins.attrNames zig.packages)
    )
    // {
      overlays.default = final: prev: {
        ghostty = self.packages.${prev.system}.default;
      };
    };

  nixConfig = {
    extra-substituters = ["https://ghostty.cachix.org"];
    extra-trusted-public-keys = ["ghostty.cachix.org-1:QB389yTa6gTyneehvqG58y0WnHjQOqgnA+wBnpWWxns="];
  };
}
