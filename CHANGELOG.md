## 0.1.0

* Initial release, extracted from frostdart: the build hook with its
  prebuilt, source, and dev modes; the Nix environment and Rust driver; the
  Apple build through a pinned Xcode; the reusable workflow that verifies
  every push on four hosts and publishes releases; and the tools that
  update the lock and verify a platform.
* `dnix.lock` is a source file written by `update_lock`: it records what the
  native source builds to and names the release, derived from the hashes,
  that holds those bytes. CI fails when the source and the lock disagree and
  publishes the release from the default branch.
