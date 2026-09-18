{
  description = "fuzzy-agent-session-search (fass) development environment";

  nixConfig = {
    extra-substituters = [ "https://forketyfork.cachix.org" ];
    extra-trusted-public-keys = [
      "forketyfork.cachix.org-1:+0f7K77HIlUgbueZCRgRHr1GM6gMAThMetrwt0DaF3U="
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, zig }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [
            just
            shellcheck
            fzf
            sqlite
            zig.packages.${system}."0.16.0"
          ];

          buildInputs = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
            pkgs.gawk
            pkgs.gnused
          ];

          shellHook = ''
            # Greet on stderr so callers that capture stdout (e.g. `nix develop
            # --command zig build lint-sarif > results.sarif` in CI) get clean
            # program output.
            echo "fuzzy-agent-session-search (fass) development environment" >&2
            echo "Available commands: just --list" >&2
          ''
          + (pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
            # On macOS, unset the macOS SDK env vars that Nix sets up because
            # we rely on a system installation.
            unset SDKROOT
            unset DEVELOPER_DIR

            # Remove "xcrun" injected by some dependency; we need system xcrun.
            export PATH=$(echo "$PATH" | ${pkgs.gawk}/bin/awk -v RS=: -v ORS=: '$0 !~ /xcrun/ || $0 == "/usr/bin" {print}' | ${pkgs.gnused}/bin/sed 's/:$//')
          '');
        };
      }
    );
}
