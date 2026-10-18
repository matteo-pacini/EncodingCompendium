{
  description = "EncodingCompendium - encoding toolchain";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      encoders =
        pkgs: with pkgs; [
          # -full: plain ffmpeg lacks libvmaf
          ffmpeg-full
          mkvtoolnix-cli
          jq
          # 2160p HDR: Dolby Vision RPUs, and the x265 CLI (only it injects them)
          dovi-tool
          x265
        ];
      # The scripts use GNU options (stat -c, readlink -f, sed -i); on macOS
      # these come first in PATH instead of the BSD tools.
      userland =
        pkgs: with pkgs; [
          bashInteractive
          coreutils
          findutils
          gawk
          gnugrep
          gnused
          ncurses
          procps
          util-linux
        ];

      # One entry script with lib/ beside it, as the scripts expect. The
      # source is the flake's repository (tracked files only), so this
      # needs a git or github flake reference with ?dir=nix, not path:./nix.
      # extraWrap: more makeWrapper options.
      script =
        pkgs: name: extraWrap:
        pkgs.stdenvNoCC.mkDerivation {
          pname = name;
          version = self.shortRev or self.dirtyShortRev or "dev";
          src = self.sourceInfo;
          nativeBuildInputs = [ pkgs.makeWrapper ];
          installPhase = ''
            mkdir -p $out/libexec/encoding-compendium $out/bin
            cp -r ${name}.sh lib $out/libexec/encoding-compendium/
            makeWrapper $out/libexec/encoding-compendium/${name}.sh $out/bin/${name} \
              --prefix PATH : ${pkgs.lib.makeBinPath (encoders pkgs ++ userland pkgs)} ${extraWrap}
          '';
          meta.mainProgram = name;
        };
    in
    {
      packages = forAllSystems (pkgs: {
        tools = pkgs.buildEnv {
          name = "encoding-compendium-tools";
          paths = encoders pkgs ++ userland pkgs;
        };
        hevc-1080p-sdr = script pkgs "hevc-1080p-sdr" "";
        hevc-2160p-hdr = script pkgs "hevc-2160p-hdr" "";
        # Workers fetch their tools from the commit this was built from.
        hevc-farm = script pkgs "hevc-farm" (
          pkgs.lib.optionalString (self ? rev)
            "--set-default FARM_REF 'github:matteo-pacini/EncodingCompendium/${self.rev}?dir=nix'"
        );
      });

      apps = forAllSystems (pkgs: {
        hevc-1080p-sdr = {
          type = "app";
          program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.hevc-1080p-sdr}/bin/hevc-1080p-sdr";
        };
        hevc-2160p-hdr = {
          type = "app";
          program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.hevc-2160p-hdr}/bin/hevc-2160p-hdr";
        };
        hevc-farm = {
          type = "app";
          program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.hevc-farm}/bin/hevc-farm";
        };
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell { packages = encoders pkgs; };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
