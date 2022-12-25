{
  description = "Example of using stacklock2nix to build a statically-linked Pandoc";

  # This is a flake reference to the stacklock2nix repo.
  #
  # Note that if you copy the `./flake.lock` to your own repo, you'll likely
  # want to update the commit that this stacklock2nix reference points to:
  #
  # $ nix flake lock --update-input stacklock2nix
  #
  # You may also want to lock stacklock2nix to a specific release:
  #
  # inputs.stacklock2nix.url = "github:cdepillabout/stacklock2nix/v1.5.0";
  inputs.stacklock2nix.url = "github:cdepillabout/stacklock2nix/main";

  # This is a flake reference to Nixpkgs.  We use the Nixpkgs branch
  # haskell-updates, since it is likely that a GHC for static-linking has been
  # built on this branch.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/haskell-updates";

  outputs = { self, nixpkgs, stacklock2nix }:
    let
      # System types to support.
      supportedSystems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];

      # Helper function to generate an attrset '{ x86_64-linux = f "x86_64-linux"; ... }'.
      forAllSystems = f: nixpkgs.lib.genAttrs supportedSystems (system: f system);

      # Nixpkgs instantiated for supported system types.
      nixpkgsFor =
        forAllSystems (system: import nixpkgs { inherit system; overlays = [ stacklock2nix.overlay self.overlay ]; });
    in
    {
      # A Nixpkgs overlay.
      overlay = final: prev: {
        # This is a top-level attribute that contains the result from calling
        # stacklock2nix.
        pandoc-stacklock = final.stacklock2nix {
          stackYaml = ./stack.yaml;

          # This is a statically-linked Haskell package set with ghc902.
          baseHaskellPkgSet = final.pkgsStatic.haskellPackages;

          # The callPackage function setup for static linking.
          callPackage = final.pkgsStatic.callPackage;

          # Any additional Haskell package overrides you may want to add.
          additionalHaskellPkgSetOverrides = hfinal: hprev: {

            # In Nixpkgs, static-linking with musl is considered
            # "cross-compiling".  When cross-compiling, all tests in Haskell
            # packages are disabled.
            #
            # However, if we disable all tests in all Haskell packages, our
            # development shell doesn't correctly pick up our test
            # dependencies, so we don't get a full GHC package database.
            #
            # In order to work around this, the following line re-enables tests
            # for all Haskell packages.  In the case of actually cross-compiling
            # to a different architecture, running tests wouldn't work (since,
            # for instance, you can't run aarch64 binaries on x86_64).  But in the
            # case of statically linking, running tests will work.
            mkDerivation = args: hprev.mkDerivation ({ doCheck = true; } // args);

            hspec = hprev.hspec.overrideAttrs (oldAttrs: {
              # It seems like lots of Haskell packages use hspec-discover, but
              # they don't declare it as a run-time test dependency.  They only
              # declare a dependency on hspec.  When not statically linking, this
              # appears to work because hspec pulls in the hspec-discover
              # executable.  But when statically linking, just depending on
              # hspec doesn't pull in the hspec-discover executable.
              #
              # This hack makes sure the hspec-discover executable is availble
              # for any package that declares a dependency on hspec.
              propagatedNativeBuildInputs = (oldAttrs.propagatedNativeBuildInputs or []) ++ [
                hfinal.hspec-discover
              ];
            });

            # Tests aren't able to find input files for some reason.
            pandoc-lua-engine = final.haskell.lib.compose.dontCheck hprev.pandoc-lua-engine;

            pandoc = final.haskell.lib.overrideCabal hprev.pandoc (oldAttrs: {
              # Pandoc requires some data files during its document conversion process.
              # Enabling the following flag causes Pandoc to embed the data files inside
              # the pandoc binary.  This makes it possible to take the statically-linked
              # binary and easily move it to another system (without also having to
              # move the external data files along with it).
              configureFlags = (oldAttrs.configureFlags or []) ++ [ "-fembed_data_files" ];
            });
          };

          # Additional packages that should be available in the development shell.
          additionalDevShellNativeBuildInputs = stacklockHaskellPkgSet: [
            final.cabal-install
            final.ghcid
            final.stack
          ];

          # We need to specify a newer all-cabal-hashes. This is necessary
          # because we are using `extraDeps` in our `stack.yaml` file that are
          # _newer_ than the `all-cabal-hashes` derivation from our Nixpkgs.
          all-cabal-hashes = final.fetchurl {
            name = "all-cabal-hashes";
            url = "https://github.com/commercialhaskell/all-cabal-hashes/archive/5f63bee036a02b814a8dc927bff17b12b64900d6.tar.gz";
            sha256 = "sha256-ooOLQgdQtp03YV5FMULDT93VPSV8eKHXA8nsKiXj1js=";
          };
        };

        # Our local statically-linked pandoc binary.
        #
        # Note that we probably don't want to actually overwrite the top-level
        # Nixpkgs attribute `pandoc`, since it would cause many other things in Nixpkgs to rebuild
        # as well.
        my-pandoc = final.pandoc-stacklock.pkgSet.pandoc-cli;

        # Development shell for using `cabal`.
        pandoc-dev-shell = final.pandoc-stacklock.devShell;
      };

      nixpkgs = forAllSystems (system: nixpkgsFor.${system});

      packages = forAllSystems (system: {
        pandoc = nixpkgsFor.${system}.my-pandoc;
      });

      defaultPackage = forAllSystems (system: self.packages.${system}.pandoc);

      devShells = forAllSystems (system: {
        pandoc-dev-shell = nixpkgsFor.${system}.pandoc-dev-shell;
      });

      devShell = forAllSystems (system: self.devShells.${system}.pandoc-dev-shell);
    };
}
