# Settings every package gets unless its dnix.json overrides them. The
# toolchain pins decide the bytes of every library, so bumping one here is a
# release event for every consumer that adopts the new dnix version.
{
  toolchains = {
    zig = "0.17.0";
    llvm = 23;
    ndk = "28.2.13676358";
    xcode = "27.0";
    # Optionally the Xcode build number too ("27A266a"): betas and the
    # release of one version share a version string but differ in SDK and
    # compiler. Empty pins the version only.
    xcodeBuild = "";
    xwin = {
      channelUrl = "https://download.visualstudio.microsoft.com/download/pr/c95450be-0a45-4779-b142-33f567ccfd6e/f24aa010ba2fd5079d502e47bf40f5932f097df4bd716234dc68175b39649401/VisualStudio.17.Release.chman";
      channelSha256 = "4f0f290bb4d58a061a49a2fa893357a8c9e7e2b49fc91873f533ab8f791e4fa0";
      splatHash = "sha256-YjmEfoxtcmQXvUc+WtaElnyP/4osNvtSI7X6MDaNTjg=";
    };
    ndkLinux = {
      url = "https://dl.google.com/android/repository/android-ndk-r28c-linux.zip";
      sha256 = "dfb20d396df28ca02a8c708314b814a4d961dc9074f9a161932746f815aa552f";
    };
  };
  floors = {
    macos = 12;
    ios = 15;
    android = 24;
    glibc = "2.28";
  };
  # Canonical prefixes source paths are remapped onto, so no build directory
  # or home directory reaches the binaries. `paths.workspace` defaults to
  # /<name>/<workspace>.
  paths = {
    registry = "/cargo/registry/src";
    registryIndex = "index.crates.io-1949cf8c6b5b557f";
  };
}
