# DimHidden: notes for agents and contributors

DimHidden is a single-file Swift menu bar app (`Sources/main.swift`) that draws click-through veils over the Dock icons of hidden apps on macOS 27. Read `README.md` for what it does and how it works.

## Layout

- `Sources/main.swift`: everything. `DockAX` reads the Dock through the Accessibility API, `VeilGeometry` turns a Dock tile frame into veil rectangles, `VeilWindow` draws one veil, `Controller` tracks hidden apps, the pointer, and the menu. `ErrorLog` writes `~/Library/Logs/DimHidden/errors.log`.
- `Info.plist`: bundle metadata and the version.
- `build.sh`: builds a universal app with `xcrun swiftc` and installs it to `~/Applications` (pass `--no-install` to only build).
- `CHANGELOG.md`: one section per version. The release workflow uses the section as release notes.
- `.github/`: CI, the safety check and independent review that gate every pull request, releases, issue forms.
- `updater/`: the maintainer's Mac updater. Not part of the app.

## Building and checking

The app only builds on macOS with the Xcode Command Line Tools: `SIGN_IDENTITY=- ./build.sh --no-install`. On Linux you can't compile it, so push your branch and let the `CI / build` check (macOS) compile it, verify the universal binary, and launch it for a smoke test. Read failures with `gh run view <id> --log-failed`.

`.github/scripts/test_safety_check.sh` tests the safety check.

## How changes reach users

1. Every change arrives as a pull request.
2. The Review workflow runs `.github/scripts/safety_check.py` and, if that passes, an independent AI review that sees only the diff.
3. When both pass, the workflow enables auto-merge for the exact reviewed commit. It merges once `CI / build` passes.
4. The Release workflow publishes `vX.Y.Z` with `DimHidden.zip` for each new version on main.
5. The maintainer's Mac rebuilds from main within 12 hours.

A pull request that fails either check is labeled `droid:needs-human` and waits for the maintainer.

## Rules for automated changes

The safety check rejects anything else, so stay inside these limits:

- Change only `Sources/*.swift`, `Info.plist` (version numbers only), `CHANGELOG.md`, `README.md`, and `docs/*.png|md`.
- Don't use processes, the network, AppleScript, the keychain, file writes or deletes, the clipboard, key or screen capture, other apps' settings, dynamic code loading, or encoded strings. `safety_check.py` lists the exact patterns. If a fix truly needs one of them, open the pull request anyway and say why in its description; a human will decide.
- Never log or send app names, file paths, or other personal data. Error log entries can end up in public issues.
- Keep a pull request under 600 changed lines.
- Bump `CFBundleShortVersionString` (patch for fixes, minor for features) and `CFBundleVersion` (+1), and add a `CHANGELOG.md` section for the new version.

The fixer bot follows `.github/fixer/playbook.md`.

## Code style

- Match the surrounding code: small types, `private` by default, comments only for why (measured constants, Dock quirks), not what.
- Geometry constants were measured from screenshots on macOS 27.2 at 32pt icons. Explain the measurement behind any constant you change.
- Keep idle CPU near zero: the display link must stop once the Dock settles, and idle work runs at most twice a second.
