# nix-darwin module: installs the app, starts it at login and adds the sudoers rule it needs.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.display-sleep-toggle;
in
{
  options.services.display-sleep-toggle = {
    enable = lib.mkEnableOption "DisplaySleepToggle, a menu bar switch that keeps the display on";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ./package.nix { }";
      description = "The DisplaySleepToggle package to use.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = config.system.primaryUser;
      defaultText = lib.literalExpression "config.system.primaryUser";
      description = "User allowed to run the app's two pmset commands without a password.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Shows up in /Applications/Nix Apps, so it can be reopened after Quit.
    environment.systemPackages = [ cfg.package ];

    launchd.user.agents.display-sleep-toggle.serviceConfig = {
      ProgramArguments = [ "${cfg.package}/Applications/DisplaySleepToggle.app/Contents/MacOS/DisplaySleepToggle" ];
      RunAtLoad = true;
      # Restart after a crash, but stay closed after Quit.
      KeepAlive.SuccessfulExit = false;
      ProcessType = "Interactive";
    };

    # Lets the app switch display sleep without a password.
    security.sudo.extraConfig = ''
      ${cfg.user} ALL=(root) NOPASSWD: /usr/bin/pmset -a displaysleep 0, /usr/bin/pmset -a displaysleep 10
    '';
  };
}
