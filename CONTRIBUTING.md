# Contributing to Claude Island

Thanks for your interest in improving Claude Island — a Dynamic Island for
Claude Code that lives in your MacBook's notch. Bug reports, ideas, and pull
requests are all welcome.

By participating you agree to abide by our [Code of Conduct](CODE_OF_CONDUCT.md).

## Ways to contribute

- **Report a bug** — open a [Bug report](https://github.com/Alex-Nikita/claude-island/issues/new?template=bug_report.yml).
- **Request a feature** — open a [Feature request](https://github.com/Alex-Nikita/claude-island/issues/new?template=feature_request.yml).
- **Report a security issue** — please do *not* file a public issue; see
  [SECURITY.md](SECURITY.md) and use a private GitHub security advisory.
- **Send a pull request** — see below.

## Development setup

**Requirements:** macOS (recent) with the Swift toolchain (Xcode or the Command
Line Tools). The app is a Swift Package — no Xcode project required.

```sh
git clone https://github.com/Alex-Nikita/claude-island.git
cd claude-island

make run       # build + launch from the checkout (dev loop)
make test      # swift test — the full suite
make install   # build, install to /Applications, relaunch
make bundle    # build the .app without installing
make clean     # remove build artifacts
```

`AppInfo.version` (`Sources/ClaudeIsland/Core/AppInfo.swift`) is the single
source of truth for the version — the Makefile stamps it into the bundle.

**Code signing:** builds are **ad-hoc signed by default**, so a fresh clone
builds with zero setup. That means macOS re-asks for keychain approval after
each rebuild; if you rebuild often, see [`docs/SIGNING.md`](docs/SIGNING.md) for
an optional stable local identity. Never commit a signing key.

## Making changes

- **Match the surrounding code.** Follow the existing style, naming, and comment
  density in the file you're editing — consistency over personal preference.
- **Keep the tests green.** Run `swift test` before you push. Add tests for new
  logic; the suite lives in `Tests/ClaudeIslandTests`. Tests must never touch
  your real `~/.claude` — use the `ClaudePaths.overrideHome` fixture helper.
- **Keep PRs focused.** One logical change per pull request is much easier to
  review than a large mixed diff.
- **Commit messages** follow [Conventional Commits](https://www.conventionalcommits.org)
  (`feat:`, `fix:`, `test:`, `chore:`, `docs:` …), matching the existing history.

## Opening a pull request

1. Fork the repo and create a topic branch off `main`.
2. Make your change; run `swift test` and `make bundle` to confirm it builds and
   passes.
3. Push and open a PR against `main`, filling out the pull request template.
4. A maintainer will review. Be ready to iterate — friendly, adversarial review
   is how this project stays honest.

## Scope & philosophy

Claude Island reads sensitive things (your Claude Code credential, prompt
contents) and is deliberately conservative about them — see
[SECURITY.md](SECURITY.md) for the threat model. Contributions that touch the
keychain, hooks, or credential paths should preserve those guarantees and
explain any change to the security posture in the PR description.

Not sure whether an idea fits? Open a feature request first and let's talk it
through before you invest in a large change.
