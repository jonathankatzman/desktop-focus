# Desktop Focus

Desktop Focus is a small macOS menu bar utility for locking yourself to the current Desktop/Space for a chosen amount of time.

When a focus lock is active, the app blocks common Space-switching shortcuts and gestures, including Control-arrow navigation, direct Control-number desktop shortcuts, Mission Control keys, and horizontal trackpad swipes. It also keeps a visible focus badge on the locked Space and snaps back if macOS allows an unexpected Space transition.

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

## Test

```sh
swift test
```

## Notes

macOS does not provide a public API to fully forbid every possible Space change. Desktop Focus blocks the common public event paths before the switch happens and keeps a snap-back fallback for anything macOS still allows through.

## License

MIT. See [LICENSE](LICENSE).
