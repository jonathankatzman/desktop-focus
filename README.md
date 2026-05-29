# Desktop Focus

Desktop Focus is a small macOS menu bar utility for locking yourself to the current Desktop/Space for a chosen amount of time.

When a focus lock is active, the app blocks common Space-switching shortcuts and gestures, including Control-arrow navigation, direct Control-number desktop shortcuts, Mission Control keys, and horizontal trackpad swipes. It also keeps a visible focus badge on the locked Space and snaps back if macOS allows an unexpected Space transition.

An escape hatch code is shown during each session. Typing the four-digit code in the menu bar panel unlocks focus early.

During an active lock, Desktop Focus temporarily disables macOS's horizontal trackpad Space-swipe preference and restores the previous setting on unlock. If the app exits unexpectedly, it restores the saved preference on the next launch.

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

On first launch, grant Accessibility access in:

```text
System Settings > Privacy & Security > Accessibility
```

Then quit and reopen Desktop Focus.

## Test

```sh
swift test
```

## Notes

macOS does not provide a public API to fully forbid every possible Space change. Desktop Focus blocks the common public event paths before the switch happens, temporarily disables the system horizontal trackpad Space-swipe setting while locked, and keeps a snap-back fallback for anything macOS still allows through.

## License

MIT. See [LICENSE](LICENSE).
