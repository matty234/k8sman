# Homebrew cask

`k8sman.rb` is a template for a cask in a personal tap. It isn't published
anywhere yet.

## One-time setup

1. Create a public repo named `matty234/homebrew-tap`. The `homebrew-` prefix
   is what lets users write `matty234/tap`.
2. Copy `k8sman.rb` to `Casks/k8sman.rb` in that repo.

## Each release

The release workflow prints the cask's `version` and `sha256` in its log. You
can also take the hash from the release's `SHA256SUMS` asset. Update both
lines in `Casks/k8sman.rb` and commit. Then check the cask:

```sh
brew audit --cask --online matty234/tap/k8sman
brew install --cask matty234/tap/k8sman
```

Users install it with:

```sh
brew install --cask matty234/tap/k8sman
```

## How it fits with in-app updates

- `auto_updates true` tells Homebrew that the app updates itself through
  Sparkle, so `brew upgrade` skips it unless you pass `--greedy`. The in-app
  update and the cask install the same zip, so they never conflict.
- Homebrew quarantines what it downloads, just like a browser. Releases
  from 0.2.8 on are notarized, so Gatekeeper lets them open. The release
  workflow removes the old "Open Anyway" `caveats` block from the tap's cask.
- Now that the app is notarized, it could go to the official
  `homebrew/cask` repo instead of a personal tap.
