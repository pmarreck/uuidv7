# NixOS module for the machine-wide uuidv7 service: the socket and service units
# shipped in the package (contrib/systemd), with the socket started at boot.
{ self }:
{ config, lib, pkgs, ... }:
let
	cfg = config.services.uuidv7;
in
{
	options.services.uuidv7 = {
		enable = lib.mkEnableOption "the machine-wide uuidv7 service (socket /run/uuidv7/uuidv7.sock)";
		package = lib.mkOption {
			type = lib.types.package;
			default = self.packages.${pkgs.stdenv.hostPlatform.system}.uuidv7;
			defaultText = lib.literalExpression "uuidv7.packages.\${system}.uuidv7";
			description = "The uuidv7 package providing the CLI and the systemd units.";
		};
	};
	config = lib.mkIf cfg.enable {
		systemd.packages = [ cfg.package ];
		systemd.sockets.uuidv7.wantedBy = [ "sockets.target" ];
		environment.systemPackages = [ cfg.package ];
	};
}
