# reniOS

A native Ren’Py library and player for iPhone and iPad. Requires iOS or iPadOS 26 or later.

## Builds

Open **Actions → iOS builds** to download an unsigned ARM64 IPA, a simulator build, and the keyboard regression screenshot and measurement. The IPA requires signing. The workflow never uses a Mac on the developer’s side.

| App | Runtime | CI |
| --- | --- | --- |
| reniOS | Ren’Py 8.5.3, SDL2 | Xcode 26 |
| reniOS Preview | Ren’Py 8.6.0 prerelease, SDL3 | Xcode 26 and 27 |

Each app has its own bundle ID and library. Xcode 27 builds use the SDL3 scene lifecycle. The workflow fetches checksum-pinned official Ren’Py SDK and Renios archives at build time. It uses no assets or binaries from Spark.

## Library

Import a ZIP, a Ren’Py Android APK, or an extracted game folder. Imports use the portable game files. A game that depends on custom native modules, an unsupported archive layout, desktop APIs, or a different Python version may fail to run. The bundled sample includes a text prompt for testing touch input.

Games and per-game saves are exposed in **Files → On My iPhone/iPad → reniOS**. Open a game’s details to export its save folder as a ZIP. Removing a game preserves saves under that game's ID. Reopen the app before starting a second game so each session gets a fresh embedded interpreter.

## Keyboard regression

The session keeps SDL's UIKit render view in its existing coordinate space while SDL handles native text input. The CI probe starts an actual Ren’Py input prompt, waits for the iOS keyboard notification, and checks that the game's viewport frame stays fixed. The probe saves the measured rectangles and a screenshot.

## Upstream components

[Ren’Py](https://www.renpy.org/doc/html/license.html), [Renios and its native runtime dependencies](https://github.com/renpy/renpy-build), and [ZIPFoundation](https://github.com/weichsel/ZIPFoundation).
