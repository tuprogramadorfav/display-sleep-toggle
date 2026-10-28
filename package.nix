{ swiftPackages, swift, rcodesign }:

swiftPackages.stdenv.mkDerivation {
  pname = "display-sleep-toggle";
  version = "1.0";
  src = ./.;
  nativeBuildInputs = [ swift rcodesign ];
  # The app holds the Accessibility permission, so it is signed with the hardened runtime: otherwise
  # any process running as the user could launch it with DYLD_INSERT_LIBRARIES and use that permission
  # to read keystrokes. rcodesign can set the runtime flag inside the nix sandbox, unlike
  # /usr/bin/codesign. It signs in postFixup because the fixup phase strips the binary and re-signs it
  # without the flag.
  #
  # The signature is ad hoc, so macOS ties the Accessibility permission to this exact build. After a
  # rebuild that changes the app, System Settings still shows it on, but it no longer applies: remove
  # DisplaySleepToggle there with -, then add it again with + from /Applications/Nix Apps. A stable
  # self-signed identity would avoid this, but the nix sandbox can't reach the keychain, and trusting
  # the bundle identifier alone would let any binary claiming it read keystrokes.
  buildPhase = ''
    swiftc -O main.swift -o DisplaySleepToggle
  '';
  installPhase = ''
    contents=$out/Applications/DisplaySleepToggle.app/Contents
    mkdir -p $contents/MacOS
    cp Info.plist $contents/
    cp DisplaySleepToggle $contents/MacOS/
  '';
  postFixup = ''
    rcodesign sign --code-signature-flags runtime $out/Applications/DisplaySleepToggle.app
  '';
}
