# Security Policy

## Supported versions

Only the latest release of Frost receives security fixes. Frost updates itself through Sparkle, so please make sure
you are on the [latest release](https://github.com/frostbar/frost/releases/latest) before reporting.

## Reporting a vulnerability

Please **do not** open a public issue for security problems. Report them privately through GitHub instead:
[Report a vulnerability](https://github.com/frostbar/frost/security/advisories/new).

Include what you found, the steps to reproduce it, the Frost and macOS versions, and the impact you expect. You
should get a first response within a week. Once a fix is released, the advisory is published and you are credited
unless you prefer otherwise.

## Scope

Frost is not sandboxed and uses Accessibility and (optionally) Screen Recording, so reports about the following are
especially welcome:

- the update mechanism (Sparkle, the appcast, EdDSA signature checks)
- the code signature, notarization or Hardened Runtime settings of released builds
- the cache of menu bar icon images in `~/Library/Caches/dev.frost.Frost/items/`
- synthesized mouse events reaching anything other than the intended menu bar item
