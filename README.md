# NetSpeed

A tiny macOS menu bar app that shows live download/upload speed.

## Features
- Live ↓/↑ speed in the menu bar (bytes/s or bits/s — toggle with ⌘B)
- Peak speeds and session totals, with reset (⌘R)
- Configurable update interval
- Launch at Login
- Uses 64-bit interface counters (no wraparound at 4 GB); ignores VPN tunnels, bridges and loopback to avoid double counting

## Install
Download `NetSpeed.zip` from the [latest release](../../releases/latest), unzip, and move `NetSpeed.app` to `/Applications`.

The app is ad-hoc signed, not notarized, so on first launch macOS will block it. Right-click → **Open**, or run:
```sh
xattr -dr com.apple.quarantine /Applications/NetSpeed.app
```

## Build from source
Requires Xcode Command Line Tools (`xcode-select --install`).
```sh
./build.sh
open NetSpeed.app
```
Produces a universal (Apple Silicon + Intel) binary. Requires macOS 12+.
