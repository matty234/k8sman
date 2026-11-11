# Security

k8sman holds credentials for your clusters, so security reports are very welcome.

## Reporting a vulnerability

Please **don't open a public issue** for a security problem. Instead, either:

- use GitHub's private reporting: the **Security** tab → **Report a vulnerability** ([link](https://github.com/matty234/k8sman/security/advisories/new)), or
- email **security@bargrove.com** with "k8sman security" in the subject.

Include what you found, how to reproduce it, the k8sman version and your OS. A proof of concept helps but isn't required.

k8sman is maintained by one person, so this is best effort. I'll aim to:

- acknowledge your report within a few days,
- keep you updated while I work on a fix,
- credit you in the release notes and advisory, unless you'd rather not be named.

Please give me a reasonable chance to ship a fix before disclosing publicly.

## Diagnostics and privacy

k8sman sends no telemetry or crash reports. Errors in the app are kept in a
local file, `~/.config/k8sman/diagnostics.json`, and listed in Settings ▸
Diagnostics. Before anything is stored, the sample messages and stacks are
redacted. IP addresses, hostnames, e-mail addresses, tokens, home folders,
recognisable object names and namespaces, and your context, cluster and
namespace names become placeholders. A report leaves your machine only if you
copy it or open a GitHub issue from that page, and you can read it before
you send it. Clear empties the log.

## Supported versions

Only the latest release gets security fixes. The app updates itself (Sparkle on macOS, the built-in updater elsewhere), so fixes reach users through a normal release.

## Scope

Things I'd especially like to hear about:

- **The local backend.** `k8sman-server` listens on loopback only and requires a per-launch token on every request. Anything that lets another local process, a web page or a remote host reach it, or bypass the token, is in scope.
- **Read-only mode.** Any way to change a cluster from a context marked read-only.
- **Credential handling.** Leaking kubeconfig contents, tokens or Secret data (to logs, crash reports, the clipboard without asking, local shells or other processes).
- **Updates.** Anything that gets an unsigned or tampered update installed. macOS builds are signed with a Developer ID and notarized, and update archives are signed with an EdDSA key.
- **Terminals and local shells.** Escape sequences or pod output that can run commands or write files on your machine.

Out of scope: problems that need an attacker who already has your kubeconfig or your user account, and the permissions your cluster itself grants (k8sman can only do what your credentials allow).
