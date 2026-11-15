# reniOS

A native Ren’Py library and player for iPhone and iPad. Requires iOS or iPadOS 26 or later.

## Builds

Open **Actions → iOS builds** for one unsigned ARM64 IPA for iOS and iPadOS 26 or later. The app builds on Xcode 27. The default engine is the Ren’Py 8.6.0 prerelease (SDL3). The IPA also bundles pinned upstream Ren’Py runtimes for these releases.

| Python | Ren’Py |
| --- | --- |
| 2.7 | 7.4.11, 7.5.3, 7.6.3, 7.7.3, 7.8.4, 7.8.7 |
| 3.9 | 8.0.3, 8.1.3, 8.2.3, 8.3.4, 8.3.7 |
| 3.12 | 8.4.1, 8.5.0, 8.5.2, 8.5.3, 8.6.0 prerelease |
 The IPA requires signing before installation.

Each run also builds one simulator app and installs that same build on iOS 26 and iOS 27 simulators. The test jobs publish keyboard screenshots and viewport measurements. GitHub-hosted Macs run every build, and CI checks the official SDK and Renios archives against pinned checksums.

## Library

Import a ZIP, a Ren’Py Android APK, or an extracted game folder. Imports use the portable game files. A game that depends on custom native modules, an unsupported archive layout, desktop APIs, or a different Python version may fail to run. The library follows device rotation. Each game can use automatic, portrait, or landscape orientation. The bundled sample includes a text prompt for testing touch input.

The importer checks the packaged Ren’Py version in game folders, ZIPs, and APKs, including version files in Android’s packaged private data. Automatic selection prefers the same major and minor series. When metadata is absent, the player uses its bundled default. Each game can select an installed engine manually. The bundled default is Ren’Py 8.6.0.

Games and per-game saves are exposed in **Files → On My iPhone/iPad → reniOS**. Open a game’s details to export its save folder as a ZIP or restore it to that game. On restore you can keep existing saves or replace matching files. Removing a game preserves saves under that game's ID. Reopen the app before starting a second game so each session gets a fresh embedded interpreter.

## Keyboard regression

The session keeps SDL's UIKit render view in its existing coordinate space while SDL handles native text input. The CI probe starts an actual Ren’Py input prompt, waits for the iOS keyboard notification, and checks that the game's viewport frame stays fixed. The probe saves the measured rectangles and attempts to capture a screenshot. It then calls the same native quit action as the Close button, accepts the sample’s confirmation, and checks that Ren’Py returns successfully.

## Upstream components

[Ren’Py](https://www.renpy.org/doc/html/license.html), [Renios and its native runtime dependencies](https://github.com/renpy/renpy-build), and [ZIPFoundation](https://github.com/weichsel/ZIPFoundation).
