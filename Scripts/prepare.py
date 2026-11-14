"""Assemble a disposable Xcode project around a pinned upstream Ren'Py port."""
import argparse
import hashlib
import json
import math
import plistlib
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tarfile
import zipfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
VERSIONS = {
    "8.5.3": {
        "renios.zip": "c4fae153e8276ed0faed5e84ea3e0b7c4bf337f0e3208e9130c6a41748a83b2b",
        "sdk.tar.bz2": "eb0a9be7f0fb13632fe25ceade9a8bed5a1b4d6b6e83bd19eeeb29e1a1bb4a45",
    },
    "8.6.0": {
        "renios.zip": "046ad6d8774389c62fe939a18de4c67e6646ba9b4d35a0c1a95e8ec3253ef504",
        "sdk.tar.bz2": "b3215982d6ce33446507b9a3f338c4dabd87b839484f01646087e2d85f143e38",
    },
}
BUNDLE_ID = "io.renios.player"
ZIP_PACKAGE_ID = "B10000000000000000000001"
ZIP_PRODUCT_ID = "B10000000000000000000002"
ZIP_BUILD_ID = "B10000000000000000000003"


def digest(path):
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def get_archive(version, archive, expected, cache):
    filename = cache / f"{version}-{archive}"
    upstream = f"https://www.renpy.org/dl/{version}/renpy-{version}-{archive}"
    if not filename.is_file():
        cache.mkdir(parents=True, exist_ok=True)
        partial = filename.with_suffix(".partial")
        try:
            subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error",
                            "--retry", "2", "--output", str(partial), upstream], check=True)
            if digest(partial) != expected:
                raise ValueError(f"Checksum mismatch for {upstream}")
            partial.replace(filename)
        finally:
            partial.unlink(missing_ok=True)
    if digest(filename) != expected:
        raise ValueError(f"Checksum mismatch for {filename}")
    return filename


def insert_after(text, marker, addition):
    if text.count(marker) != 1:
        raise ValueError(f"Unexpected upstream project layout around {marker!r}")
    return text.replace(marker, marker + addition, 1)


def configure_project(project, version):
    config = project.read_text()
    config = config.replace("main.c", "Host.m").replace("sourcecode.c.c; path = Host.m", "sourcecode.c.objc; path = Host.m")
    config = re.sub(r"IPHONEOS_DEPLOYMENT_TARGET = [\d.]+;", "IPHONEOS_DEPLOYMENT_TARGET = 26.0;", config)
    config = re.sub(r"\n\s*(?:DEVELOPMENT_TEAM|DevelopmentTeam|SWIFT_VERSION) = [^;]+;", "", config)
    config = config.replace("org.renpy.prototype", BUNDLE_ID).replace("PRODUCT_NAME = prototype;", "PRODUCT_NAME = reniOS;")
    config = config.replace("prototype.app", "reniOS.app").replace('"-lstdc++"', '"-lc++"')
    # Use the simulator archive directory in either configuration.
    config = config.replace(
        'LIBRARY_SEARCH_PATHS = "$(SRCROOT)/prebuilt/release/";',
        'LIBRARY_SEARCH_PATHS = "$(inherited)";\n'
        '\t\t\t\t"LIBRARY_SEARCH_PATHS[sdk=iphoneos*]" = "$(SRCROOT)/prebuilt/release";\n'
        '\t\t\t\t"LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*]" = "$(SRCROOT)/prebuilt/debug";'
    )
    config = config.replace(
        'USER_HEADER_SEARCH_PATHS = "";',
        'USER_HEADER_SEARCH_PATHS = "";\n'
        f'\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = ("$(inherited)", "RENIOS_SDL3={int(version == "8.6.0")}");\n'
        '\t\t\t\tSWIFT_VERSION = 5.0;\n'
        '\t\t\t\tSWIFT_OBJC_BRIDGING_HEADER = "$(SRCROOT)/Host.h";'
    )
    target_marker = '\t\t\tproductType = "com.apple.product-type.application";'
    config = insert_after(config, target_marker, f"\n\t\t\tpackageProductDependencies = ({ZIP_PRODUCT_ID},);")
    config = re.sub(r"(\n\t\t\tprojectDirPath = )", f"\n\t\t\tpackageReferences = ({ZIP_PACKAGE_ID},);\\1", config, count=1)
    config = insert_after(config, "/* Begin PBXBuildFile section */",
                          f"\n\t\t{ZIP_BUILD_ID} = {{isa = PBXBuildFile; productRef = {ZIP_PRODUCT_ID}; }};")
    framework_phase = re.compile(r"(isa = PBXFrameworksBuildPhase;\s*buildActionMask = \d+;\s*files = \()")
    config, count = framework_phase.subn(rf"\g<1>\n\t\t\t\t{ZIP_BUILD_ID},", config)
    if count != 1:
        raise ValueError("Expected one upstream frameworks phase")

    for index, name in enumerate(("reniOS.swift", "Library.swift"), 4):
        reference = f"B100000000000000000000{index:02d}"
        build = f"B100000000000000000001{index:02d}"
        config = insert_after(config, "/* Begin PBXFileReference section */",
                              f'\n\t\t{reference} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};')
        config = insert_after(config, "/* Begin PBXBuildFile section */",
                              f"\n\t\t{build} = {{isa = PBXBuildFile; fileRef = {reference}; }};")
        config = insert_after(config, "E2845E1E1A350A57004BC3F8 /* Host.m */,", f"\n\t\t\t\t{reference},")
        config = insert_after(config, "E2845E1F1A350A57004BC3F8 /* Host.m in Sources */,", f"\n\t\t\t\t{build},")
    config = insert_after(config, "/* End XCConfigurationList section */", f'''
        {ZIP_PACKAGE_ID} = {{
            isa = XCRemoteSwiftPackageReference;
            repositoryURL = "https://github.com/weichsel/ZIPFoundation.git";
            requirement = {{kind = exactVersion; version = 0.9.20;}};
        }};
        {ZIP_PRODUCT_ID} = {{
            isa = XCSwiftPackageProductDependency;
            package = {ZIP_PACKAGE_ID};
            productName = ZIPFoundation;
        }};
''')
    # Keep the upstream SDL scene manifest on SDL3, and the library's existing
    # application lifecycle on SDL2. Xcode 26 is used for the SDL2 variant.
    project.write_text(config)


def app_icon(prototype):
    icon = prototype / "Media.xcassets" / "AppIcon.appiconset"
    shutil.rmtree(icon)
    icon.mkdir()
    size = 1024

    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    rows = bytearray()
    for y in range(size):
        rows.append(0)
        for x in range(size):
            radius = math.hypot(x - 520, y - 490)
            glow = max(0.0, 1 - radius / 660)
            if 4 > min(abs(radius - ring) for ring in (267, 322, 379)):
                pixel = (107, 83, 84)
            elif (350 < x < 418 and 347 < y < 691) or (399 < x < 650 and 330 < y < 395 and x + y < 1030):
                pixel = (243, 226, 193)
            else:
                pixel = (int(18 + 24 * glow), int(20 + 17 * glow), int(28 + 19 * glow))
            rows.extend(pixel)
    (icon / "renios.png").write_bytes(
        b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b"")
    )
    (icon / "Contents.json").write_text(json.dumps({
        "images": [{"filename": "renios.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
        "info": {"author": "xcode", "version": 1},
    }))


def prepare(version, cache):
    archives = {name: get_archive(version, name, sha, cache) for name, sha in VERSIONS[version].items()}
    build = ROOT / ".build" / "project"
    if build.exists():
        shutil.rmtree(build)
    build.mkdir(parents=True)
    with zipfile.ZipFile(archives["renios.zip"]) as archive:
        archive.extractall(build)
    prototype = build / "renios" / "prototype"
    prefix = f"renpy-{version}-sdk"
    with tarfile.open(archives["sdk.tar.bz2"]) as archive:
        def needed(entry):
            path = Path(entry.name)
            if not path.parts or path.parts[0] != prefix:
                return False
            relative = path.parts[1:]
            return relative[:1] == ("renpy",) or relative[:2] == ("lib", "python3.12") or relative == ("renpy.py",)

        archive.extractall(build, members=(entry for entry in archive if needed(entry)), filter="data")

    sdk = build / prefix
    base = prototype / "base"
    base.joinpath("lib").mkdir(parents=True)
    shutil.move(sdk / "renpy", base / "renpy")
    shutil.move(sdk / "lib" / "python3.12", base / "lib" / "python3.12")
    shutil.move(sdk / "renpy.py", base / "renpy_entry.py")
    shutil.copyfile(ROOT / "Scripts" / "engine_main.py", base / "main.py")
    shutil.copytree(ROOT / "Demo", base / "Demo")
    for source in (ROOT / "App").iterdir():
        if source.is_file():
            shutil.copyfile(source, prototype / source.name)

    plist_path = prototype / "Info.plist"
    plist = plistlib.loads(plist_path.read_bytes())
    plist.update({
        "CFBundleDisplayName": "reniOS" if version == "8.5.3" else "reniOS Preview",
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "1",
        "CFBundleDocumentTypes": [{
            "CFBundleTypeName": "Ren’Py archive",
            "LSHandlerRank": "Alternate",
            "LSItemContentTypes": ["public.zip-archive", "io.renios.apk"],
        }],
        "UTImportedTypeDeclarations": [{
            "UTTypeIdentifier": "io.renios.apk",
            "UTTypeDescription": "Android package",
            "UTTypeConformsTo": ["public.zip-archive"],
            "UTTypeTagSpecification": {"public.filename-extension": ["apk"]},
        }],
        "ReniosEngineVersion": version,
        "LSSupportsOpeningDocumentsInPlace": True,
        "UIFileSharingEnabled": True,
        "UIApplicationSupportsIndirectInputEvents": True,
    })
    plist.pop("UIRequiresFullScreen", None)
    plist.pop("UILaunchStoryboardName", None)
    plist["UILaunchScreen"] = {}
    if version == "8.6.0":
        plist["CFBundleIdentifier"] = BUNDLE_ID + ".preview"
    plist_path.write_bytes(plistlib.dumps(plist))
    app_icon(prototype)
    project = prototype / "prototype.xcodeproj" / "project.pbxproj"
    configure_project(project, version)
    if version == "8.6.0":
        project.write_text(project.read_text().replace(BUNDLE_ID, BUNDLE_ID + ".preview"))
    print(project.parent)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("engine", choices=VERSIONS)
    parser.add_argument("--cache", type=Path, default=ROOT / ".build" / "downloads")
    arguments = parser.parse_args()
    prepare(arguments.engine, arguments.cache)
