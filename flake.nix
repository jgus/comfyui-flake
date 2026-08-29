{
  description = "ComfyUI: node-based AI image/video generation runtime, packaged from upstream comfyanonymous/ComfyUI.";

  inputs = {
    # Heavy AI deps (torch, CUDA) live on unstable — kept in sync with unsloth-studio for store-path cache reuse.
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    flake-lib = {
      url = "github:jgus/flake-lib/v1";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };

    # Per-dep sibling flakes, each tracking one PyPI package.
    # Each follows this flake's flake-lib so the lockfile carries a single shared flake-lib node.
    spandrel = {
      url = "github:jgus/spandrel-flake";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
      inputs.flake-lib.follows = "flake-lib";
    };
    comfyui-frontend-package = {
      url = "github:jgus/comfyui-frontend-package-flake/v1.49.6";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
      inputs.flake-lib.follows = "flake-lib";
    };
    comfyui-workflow-templates = {
      url = "github:jgus/comfyui-workflow-templates-flake/v0.11.48";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
      inputs.flake-lib.follows = "flake-lib";
    };
    comfyui-embedded-docs = {
      url = "github:jgus/comfyui-embedded-docs-flake/v0.5.10";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
      inputs.flake-lib.follows = "flake-lib";
    };
    comfy-kitchen = {
      url = "github:jgus/comfy-kitchen-flake/v0.2.31";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
      inputs.flake-lib.follows = "flake-lib";
    };
    comfy-aimdo = {
      url = "github:jgus/comfy-aimdo-flake/v0.4.15";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
      inputs.flake-lib.follows = "flake-lib";
    };
  };

  outputs =
    { self
    , nixpkgs
    , flake-utils
    , flake-lib
    , spandrel
    , comfyui-frontend-package
    , comfyui-workflow-templates
    , comfyui-embedded-docs
    , comfy-kitchen
    , comfy-aimdo
    }:
    let
      pin = import ./pin.nix;
      inherit (pin) version sourceRev sourceHash;
      source = { type = "github"; owner = "comfyanonymous"; repo = "ComfyUI"; };

      overlay = final: prev:
        let
          inherit (final.stdenv.hostPlatform) system;
          src = final.fetchFromGitHub {
            owner = "comfyanonymous";
            repo = "ComfyUI";
            rev = sourceRev;
            hash = sourceHash;
          };
        in
        {
          # Inject each sibling-built PyPI package into python3.pkgs so the comfyui derivation's `withPackages` lookup resolves them. Pre-built means we don't rebuild torch transitively for each sibling — each came in as a pure-Python wheel/sdist.
          python3 = prev.python3.override (old: {
            packageOverrides = nixpkgs.lib.composeExtensions
              (old.packageOverrides or (_: _: { }))
              (pyfinal: _pyprev: {
                spandrel = spandrel.packages.${system}."spandrel";
                comfyui-frontend-package = comfyui-frontend-package.packages.${system}."comfyui-frontend-package";
                comfyui-workflow-templates = comfyui-workflow-templates.packages.${system}."comfyui-workflow-templates";
                comfyui-embedded-docs = comfyui-embedded-docs.packages.${system}."comfyui-embedded-docs";
                comfy-kitchen = comfy-kitchen.packages.${system}."comfy-kitchen";
                comfy-aimdo = comfy-aimdo.packages.${system}."comfy-aimdo";
              });
          });

          # Top-level ComfyUI derivation: stdenv.mkDerivation with a baked python env + wrapper, kapowarr-style. Consumers get a `comfyui` binary from `pkgs.comfyui`; no withPackages dance required at the consumer level.
          comfyui = final.callPackage ./pkgs/comfyui {
            inherit src version;
          };

          # In-tree ComfyUI custom node: provides server-side missing-models download for the web frontend (the desktop-only path doesn't exist on web). The bundle-side hook is applied at frontend BUILD time by the postPatch in flakes/comfyui-frontend-package/. This derivation just packages the source tree for read-only bind-mount into the container's custom_nodes/ dir.
          comfyui-web-model-installer = final.callPackage ./pkgs/web-model-installer { };
        };
    in
    flake-utils.lib.eachDefaultSystem
      (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
          overlays = [ overlay ];
        };
      in
      {
        packages = {
          inherit (pkgs) comfyui;
          update-version = flake-lib.lib.mkUpdateVersion {
            inherit pkgs source;
            buildAttr = "comfyui";
            siblings = map
              (reqName: {
                inherit reqName;
                pypiName = reqName;
                flakeRepo = "jgus/${reqName}-flake";
                mode = "exact";
              })
              [
                "comfyui-frontend-package"
                "comfyui-workflow-templates"
                "comfyui-embedded-docs"
                "comfy-kitchen"
                "comfy-aimdo"
              ];
          };
          update-branches = flake-lib.lib.mkUpdateBranches {
            inherit pkgs source;
            pinSchema = "github";
            branchOwnedFiles = [
              "flake.nix"
              "pin.nix"
              "flake.lock"
            ];
          };
          default = pkgs.comfyui;
        };
      }) // {
      overlays.default = overlay;
    };
}
