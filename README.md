# Desktop Focus

Desktop Focus is a small macOS menu bar utility for locking yourself to the current Desktop/Space for a chosen amount of time.

When a focus lock is active, the app blocks common Space-switching shortcuts, including Control-arrow navigation, direct Control-number desktop shortcuts, and Mission Control keys. It intercepts horizontal swipe events when macOS delivers them to the app’s input filter and leaves normal scrolling available. A badge marks the locked Space, and the app tries to return there if macOS allows a switch.

The lock ends automatically when the chosen time is up. Typing the four-digit escape code in the menu bar panel unlocks focus early.

## Requirements

- macOS 13 or newer
- Xcode command line tools
- Accessibility permission for Desktop Focus

Desktop Focus is intentionally not sandboxed because it uses a global event tap to intercept Space-switching input.

## Build

```sh
./build.sh
```

The build script creates and ad-hoc signs `DesktopFocus.app` in the project directory.

For repeated builds, set `CODE_SIGN_IDENTITY` to your Apple Development signing identity. This keeps the app’s signing identity stable so Accessibility approval can survive updates.

## Install

```sh
cp -R DesktopFocus.app /Applications/
open /Applications/DesktopFocus.app
```

If the app asks for Accessibility access when you start a lock, open:

```text
System Settings > Privacy & Security > Accessibility
```

Enable Desktop Focus, adding the app to the list if needed, then try starting the lock again.

If macOS is protecting password input, finish signing in before starting a session. Keyboard blocking is unavailable while Secure Event Input is active.

## Test

```sh
swift test
```

## Notes

macOS does not provide a public API to fully forbid every possible Space change. Desktop Focus tries to return to the locked Space after a switch. If macOS keeps you on another Space, the menu bar panel asks you to switch back manually while the countdown continues.

## License

MIT. See [LICENSE](LICENSE).
