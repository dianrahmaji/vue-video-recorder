{
  description = "Vue Video Recorder project's flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, utils }:
    utils.lib.eachDefaultSystem (system:
      let
        pkgs = (import (nixpkgs) { inherit system; });
      in {
        devShell = pkgs.mkShell {
	        buildInputs = with pkgs; [
            nodejs_24
            pnpm
          ];
        };
      }
    );
}
