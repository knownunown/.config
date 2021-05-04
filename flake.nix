{
  description = "{system, home} configuration flake";

  inputs = {
    # Track an arbitrary unstable revision that I like.
    unstable.url = "nixpkgs/nixpkgs-unstable";
    nixpkgs.follows = "unstable";
    darwin.url = "github:lnl7/nix-darwin/master";
    darwin.inputs.nixpkgs.follows = "nixpkgs";

    sops-nix.url = "github:knownunown/sops-nix/age-support";
    sops-nix.inputs.nixpkgs.follows = "unstable";

    rocm.url = "github:nixos-rocm/nixos-rocm";
    rocm.flake = false;

    home-manager.url = "github:nix-community/home-manager/master";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    deploy-rs.url = "github:serokell/deploy-rs";
    deploy-rs.inputs.nixpkgs.follows = "nixpkgs";

    cachix.url = "github:jonascarpay/declarative-cachix";
    cachix.flake = false;

    speedy.url = "/home/tny/dev/speedy/";
  };

  # Cargo culted.
  # https://github.com/nix-community/home-manager/issues/1538#issuecomment-706627100
  outputs = inputs@{ self, nixpkgs, unstable, darwin, sops-nix, rocm, home-manager, deploy-rs, cachix, speedy }:
    let lib = nixpkgs.lib;
        nixConf = system: {
          # Pin flake versions for use with nix shell.
          nix = {
            registry = {
              nixpkgs.flake = nixpkgs;
              unstable.flake = unstable;
              s.flake = self;
              u.flake = unstable;
            };
            gc = {
              automatic = true;
              dates = "weekly";
              options = "--delete-older-than 14d";
            };

            package = nixpkgs.legacyPackages.${system}.nixFlakes;
            extraOptions = ''
                experimental-features = nix-command flakes
'';
            autoOptimiseStore = true;
          };
        };
    in rec {
      devShell."x86_64-linux" = let pkgs =
        nixpkgs.legacyPackages."x86_64-linux"; in pkgs.mkShell {
          sopsAgeKeyDirs = [
            ./keys
          ];
          buildInputs = with pkgs; [
            deploy-rs.defaultPackage."x86_64-linux"
            (pkgs.writeShellScriptBin "nrb" "sudo nixos-rebuild -L switch --flake .")
            (pkgs.writeShellScriptBin "hrb" "nix build --show-trace -L .#homeConfigurations.navi.activationPackage && result/activate")
            nixfmt

            (pkgs.callPackage sops-nix {}).sops-age-hook
          ];
        };
      overlays = {
        unstable = (final: prev: rec {
          # overlay unstable into our stable nixpkgs set.
          unstable = import inputs.unstable {
            system = final.system;

            config.allowUnfree = true;
          };
        });
        personal = (import ./overlays/overlays.nix);
      };

      legacyPackages =
        let system = "x86_64-linux";
            lpkgs = (import nixpkgs { inherit system; config.allowUnfree = true; });
        in {
          ${system} = (lpkgs // overlays.personal lpkgs lpkgs);
        };

      overlaysList = lib.mapAttrsToList (s: t: t) self.overlays;

      # this is factored out to account for the disparate home directory locations that I deal with,
      # namely macOS's /Users vs traditionally Linux's /home.
      homeConfiguration = { system, config, homeDirectory, username ? "tny" }:
        home-manager.lib.homeManagerConfiguration {
          inherit system homeDirectory username;
          configuration = {
            nixpkgs.overlays = overlaysList;
            imports = [ ./home.nix ];
          };
        };

      machines = {
        navi = rec {
          system = "x86_64-linux";

          config =
            let mkModule = path: (args@{ config, lib, pkgs, ... }:
                  import path ({
                    # is there a better way to do this?
                    pkgs = import inputs.unstable {
                      inherit system;
                    };
                  } // removeAttrs args ["pkgs"]));
            in nixpkgs.lib.nixosSystem {
              inherit system;

              modules = [
                (import cachix)
                {
                  cachix = [
                    { name = "nixos-rocm"; sha256 = "1l2g8l55b6jzb84m2dcpf532rm7p2g4dl56j3pbrfm03j54sg0v0"; }
                  ];
                }
                (nixConf system)
                # cachix
                { nixpkgs.overlays = self.overlaysList ++ [(import rocm)]; }

                ./configuration.nix
                ./machines/navi.nix
                ./modules/security.nix
                ./modules/corefreq.nix
                ./modules/desktop.nix
                ./modules/jenkins-agent.nix
                ./modules/minecraft-server.nix
                sops-nix.nixosModules.sops
              ];
            };

          home = homeConfiguration {
            inherit system config;

            homeDirectory = "/home/tny/";
          };
        };

        psyche = rec {
          #ignore = true;
          system = "x86_64-linux";

          config =
            let mkModule = path: (args@{ config, lib, pkgs, ... }:
                  import path ({
                    # is there a better way to do this?
                    pkgs = import inputs.unstable {
                      inherit system;
                    };
                  } // removeAttrs args ["pkgs"]));
            in nixpkgs.lib.nixosSystem {
              inherit system;

              modules = [
                (nixConf system)
                {
                  nixpkgs.overlays = self.overlaysList;
                }
                {
                  fileSystems."/" = {
                    device = "/dev/disk/by-label/root";
                    fsType = "btrfs";
                  };
                  boot.loader.grub.device = "/dev/vda";
                }
                speedy.nixosModule

                ./psyche-configuration.nix
              ];
            };
        };

        venus = rec {
          system = "x86_64-darwin";

          config = darwin.lib.darwinSystem {
            modules = [
              (nixConf system)
              ./darwin-configuration.nix
            ];
          };

          home = homeConfiguration {
            inherit system config;

            homeDirectory = "/Users/apan/";
          };
        };
      };


      # cachix = (import inputs.cachix);
      darwinConfigurations = (builtins.mapAttrs (k: v: v.config)
        (lib.filterAttrs (k: v: lib.hasSuffix "darwin" v.system) machines));
      nixosConfigurations = (builtins.mapAttrs (k: v: v.config)
        (lib.filterAttrs (k: v: lib.hasSuffix "linux" v.system && !(v ? ignore)) machines));
      homeConfigurations = builtins.mapAttrs (k: v: v.home) machines;

      deploy.nodes.psyche = {
        sshUser = "root";
        hostname = "psyche.tny.town";
        profiles.system = {
          user = "root";
          path = deploy-rs.lib.x86_64-linux.activate.nixos self.machines.psyche.config;
        };
      };

      # checks = builtins.mapAttrs (system: deployLib: deployLib.deployChecks self.deploy) deploy-rs.lib;
    };
}
