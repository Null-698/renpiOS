"""Embed independently linked upstream Renios engines in the same app bundle."""
import argparse
import plistlib
from pathlib import Path
import re
import subprocess

SDK_SETTINGS = {
    "iphoneos": ("arm64-apple-ios26.0", "release"),
    "iphonesimulator": ("arm64-apple-ios26.0-simulator", "debug"),
}
ENTRY_POINTS = ("launcher_main", "SDL_SetMainReady", "SDL_PushEvent", "SDL_iPhoneSetEventPump")


def isolate_sdl(source, output, namespace):
    # UIKit's Objective-C runtime registers class names process-wide, even for
    # locally loaded Mach-O images. Rename SDL2's own classes consistently in
    # both symbol tables and runtime metadata, preserving all binary offsets.
    contents = source.read_bytes()
    classes = set(re.findall(rb"_OBJC_CLASS_\$_(SDL[A-Za-z0-9_]+)\x00", contents))
    required = {b"SDL_uikitwindow", b"SDL_uikitviewcontroller"}
    if not required <= classes or len(namespace) != len(b"SDL"):
        raise ValueError("Unexpected SDL2 UIKit archive")
    names = re.compile(b"|".join(sorted(classes, key=lambda name: (-len(name), name))))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(names.sub(lambda match: namespace + match.group()[3:], contents))


def embed(version, namespace, app, sdk):
    target, configuration = SDK_SETTINGS[sdk]
    work = Path(".build/project/engines") / version
    prototype = work / "renios" / "prototype"
    project = (prototype / "prototype.xcodeproj" / "project.pbxproj").read_text()
    ldflags = re.findall(r'"(-l[^"]+)"', re.findall(r"OTHER_LDFLAGS = \(([^)]*)\);", project)[-1])
    archives = prototype / "prebuilt" / configuration
    python_libraries = list(archives.glob("libpython*.a"))
    if len(python_libraries) != 1:
        raise ValueError(f"Expected one Python ABI in Ren’Py {version}")
    # Several Ren’Py 7 packs list the Ren’Py 8 library in the shared template.
    python_flag = "-l" + python_libraries[0].name.removeprefix("lib").removesuffix(".a")
    ldflags = [python_flag if flag.startswith("-lpython") else flag for flag in ldflags]
    if "-lSDL2" not in ldflags:
        raise ValueError(f"Expected SDL2 in Ren’Py {version}")
    isolated = work / sdk / "libSDL2.a"
    isolated.parent.mkdir(parents=True, exist_ok=True)
    arm_archive = isolated.with_name("SDL2-arm64.a")
    source = archives / isolated.name
    architectures = subprocess.check_output(["xcrun", "lipo", "-archs", str(source)], text=True).split()
    if len(architectures) > 1:
        subprocess.run(["xcrun", "lipo", "-thin", "arm64", str(source), "-output", str(arm_archive)], check=True)
        source = arm_archive
    isolate_sdl(source, isolated, namespace.encode("ascii"))
    subprocess.run(["xcrun", "ranlib", str(isolated)], check=True)
    arm_archive.unlink(missing_ok=True)
    ldflags = [str(isolated) if flag == "-lSDL2" else "-lc++" if flag == "-lstdc++" else flag for flag in ldflags]
    name = "RenPy" + version.replace(".", "_")
    framework = app / "Frameworks" / f"{name}.framework"
    framework.mkdir(parents=True, exist_ok=True)
    sysroot = subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True).strip()
    command = [
        "xcrun", "--sdk", sdk, "clang", "-dynamiclib", "-target", target, "-isysroot", sysroot,
        "-Wl,-dead_strip", "-Xlinker", "-install_name", "-Xlinker", f"@rpath/{name}.framework/{name}",
        "-L", str(archives), "-F", str(app / "Frameworks"),
    ]
    for symbol in ENTRY_POINTS:
        command.extend(["-Xlinker", "-u", "-Xlinker", f"_{symbol}",
                        "-Xlinker", "-exported_symbol", "-Xlinker", f"_{symbol}"])
    systems = set(re.findall(r"path = System/Library/Frameworks/([A-Za-z0-9]+)\.framework", project))
    # SDL2 directly references AVAudioSession and the fixed-function GLES renderer.
    systems.update(("AVFoundation", "OpenGLES"))
    if "MetalANGLE.xcframework" in project:
        systems.add("MetalANGLE")
    for system in sorted(systems):
        command.extend(["-framework", system])
    subprocess.run([*command, *ldflags, "-o", str(framework / name)], check=True)
    (framework / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleName": name,
        "CFBundleExecutable": name,
        "CFBundleIdentifier": f"io.renios.runtime.{name}",
        "CFBundlePackageType": "FMWK",
        "CFBundleVersion": "1",
        "CFBundleShortVersionString": version,
        "CFBundleSupportedPlatforms": ["iPhoneOS" if sdk == "iphoneos" else "iPhoneSimulator"],
        "MinimumOSVersion": "26.0",
    }))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("sdk", choices=SDK_SETTINGS)
    args = parser.parse_args()
    info = plistlib.loads((args.app / "Info.plist").read_bytes())
    for version, namespace in info["ReniosLegacyNamespaces"].items():
        print(f"Linking Ren’Py {version} for {args.sdk}", flush=True)
        embed(version, namespace, args.app, args.sdk)
