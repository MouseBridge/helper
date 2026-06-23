# MouseBridge Helper

`mousebridge-helper` is the macOS-side input helper for MouseBridge.

It is responsible for:

- capturing local keyboard and mouse input via `CGEventTap`
- reporting hotkeys and edge-switch hits back to the daemon
- injecting remote mouse and keyboard input into macOS

## Build

```bash
cd helper
swift build
```

## Run

Start the matching daemon first, then launch the helper with the same `data-dir`:

```bash
./.build/debug/mousebridge-helper --data-dir /path/to/runtime-data-b
```

The helper reads `config.json` from that data directory and connects to the daemon's local Unix socket.

## Requirements

- macOS 13+
- Accessibility permission for the terminal or app launching the helper

## Typical Local Verification

From the repository root:

```bash
./verify/local-two-node-macos.sh start
```

This launches two local daemons plus two helpers for sender/receiver testing on one machine.
