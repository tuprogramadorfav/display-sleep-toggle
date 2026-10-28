# DisplaySleepToggle

A small macOS menu bar switch that keeps your display on. Turn it on and the display never sleeps; turn it off and it goes back to sleeping after 10 minutes of inactivity, on battery and on power adapter alike.

It also gives you a keyboard shortcut to dim the built-in screen and keep the Mac awake in one press, which is handy for long downloads, builds or presentations on an external monitor.

## What it does

| Action | Result |
|---|---|
| Click the menu bar switch | Toggles display sleep between **Never** and **10 minutes** |
| **Cmd + Brightness Down** | Switches to Never and dims the built-in screen to minimum |
| **Brightness Up** after that | Restores the previous brightness and switches back to 10 minutes |
| **fn-Cmd-F1** | Toggles display mirroring (macOS normally uses Cmd + Brightness Down for this) |
| Close the lid with an external display | Switches to Never so the external display stays on; opening the lid switches back |
| Right-click (or Ctrl-click) the switch | Shows the current setting, the dim action and Quit |

These map to **Turn display off on battery when inactive** and **Turn display off on power adapter when inactive** in System Settings > Lock Screen. The switch shows on only when both are Never. Your Mac locks when the display turns off if you require a password after sleep, so turning the switch on also keeps the Mac unlocked while you are away.

Requires macOS 13 or later. The Nix package is for Apple Silicon (nixpkgs dropped Intel Macs); `install.sh` works on both.

## Install

### With nix-darwin

Add the flake as an input and enable the module:

```nix
{
  inputs.display-sleep-toggle.url = "github:tuprogramadorfav/display-sleep-toggle";
  inputs.display-sleep-toggle.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { nix-darwin, display-sleep-toggle, ... }: {
    darwinConfigurations.mac = nix-darwin.lib.darwinSystem {
      modules = [
        display-sleep-toggle.darwinModules.default
        { services.display-sleep-toggle.enable = true; }
        # ...
      ];
    };
  };
}
```

The module installs the app into /Applications/Nix Apps, starts it at login, and adds the sudoers rule for `system.primaryUser` (set `services.display-sleep-toggle.user` to use someone else).

### Without Nix

You need Xcode or the Command Line Tools (`xcode-select --install`). Then:

```sh
git clone https://github.com/tuprogramadorfav/display-sleep-toggle.git
cd display-sleep-toggle
./install.sh
```

This builds the app into ~/Applications, starts it at login and adds the sudoers rule. Run it again to update; run `./uninstall.sh` to remove everything.

### Allow Accessibility

The brightness key shortcuts need the Accessibility permission. The app asks for it on first launch; you can also grant it in System Settings > Privacy & Security > Accessibility. The menu bar switch works without it.

**After every update that changes the app's code, grant it again.** The app is signed ad hoc, so macOS ties the permission to the exact build. After an update System Settings still shows it switched on, but it no longer applies. Select DisplaySleepToggle, remove it with **-**, then add it again with **+**.

## Permissions and security

- **sudo, for two commands only.** macOS needs root to change display sleep, so the installer adds a rule that lets your user run exactly `pmset -a displaysleep 0` and `pmset -a displaysleep 10` without a password, and nothing else. Any program running as you can use that rule too, so the most it can do is keep your display from sleeping.
- **Accessibility**, to see Cmd + Brightness Down and Brightness Up before macOS acts on them. macOS only offers this as a tap on all keys, but the app acts on those two keys alone and passes every other key through untouched. It never stores keystrokes, has no network access code, and, like every app, can't see what you type into password fields. The app is built with the hardened runtime, so other programs can't load their code into it to borrow this permission.
- **A private macOS framework (DisplayServices)** to read and set the built-in screen's brightness, since Apple Silicon has no public API for it. It's loaded from /System, which macOS protects from changes.

**Keeping the display on also keeps your Mac unlocked.** macOS locks when the display turns off, so while the switch is on, walking away leaves your Mac open. Cmd + Brightness Down makes this easy to miss: the screen looks off, but it's only dimmed. Lock it with Ctrl-Cmd-Q when you step away.

## License

[MIT](LICENSE)
