"""Assemble a disposable Xcode project around a pinned upstream Ren'Py port."""
import argparse
from concurrent.futures import ThreadPoolExecutor
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
    "7.4.11": {
        "renios.zip": "3052ee77e6bad39f0e672eba8146efca2ff5902c591f0d6f431759e4546f153c",
        "sdk.tar.bz2": "a73378f06a5925ea0d163b5825c298ed65dafb3d0cdccd9f34d7eace46adef1f"
    },
    "7.5.3": {
        "renios.zip": "8e123448f13d3e5f78817132e1cef1d607920457f4d6756e64a15164c99f5466",
        "sdk.tar.bz2": "6ec8c5beb93826b04afeb27b0cbc3e479672191a869bc3e4a1b88dd95cdd515a"
    },
    "7.6.3": {
        "renios.zip": "79d682be6db93f2a64edebbe1fb8805c7eadc5112e562e639974ce1a09a1e74a",
        "sdk.tar.bz2": "556ea40922e304460d50bd3eb335ab9ddce988390dbbf9f7aa77dde4ae959be1"
    },
    "7.7.3": {
        "renios.zip": "24fee886f54dfe5a8e988b721120096e5ace6023b482f5cc85b83af0acec409c",
        "sdk.tar.bz2": "f533db84e471a18895ff8914ae187bb5a008d2e99a73d8ecc1a4dcbfa5b83c67"
    },
    "7.8.4": {
        "renios.zip": "1f6ead410ef20093f9b176a73271f0662d4213a6a1db14d0ea02a25c84e53223",
        "sdk.tar.bz2": "38e77cdde0bdb06905361b31fe72f5a1f45da32bb0d850ef1c67b426a308ec6d"
    },
    "7.8.7": {
        "renios.zip": "faaabec4ec65efa8803a5a7222f6e40183c5fe8354c1ee4eeb78e978826cee86",
        "sdk.tar.bz2": "65466068af7c181a143f13d84b0ddf7a6aa58dd8d26e7ccd97cdcadecabcae5a"
    },
    "8.0.3": {
        "renios.zip": "f31b28adc35b23396a83d21912ffd5ca344197928212e0a9a1833a14953348dd",
        "sdk.tar.bz2": "7e91576c943342791bf2aceb067bb97991c063831b387536973a01f842543f25"
    },
    "8.1.3": {
        "renios.zip": "27988dc672b2753683f64211dfe39cf87f90aed64948cd9ce2d9be7756fe01cc",
        "sdk.tar.bz2": "b15fdaf1322f18aaa1a588761f52543683aefd1a3c9e45c5bf045e3a4ad468b7"
    },
    "8.2.3": {
        "renios.zip": "7c0e81566873d737ebf48fc88af5df89c097d173e325a86dc98e9546d3bfed3e",
        "sdk.tar.bz2": "0043c0110654d9c526ddf6419c800fc99ddf35dea8993ebf2126c4b2f16c90c2"
    },
    "8.3.4": {
        "renios.zip": "b180adff822ea2b3214cca1981c98f287d900bb433b1f45c1c35ce5e379824db",
        "sdk.tar.bz2": "6027241f785998d1ffc77793cf9a3c8b072f41379bb61516085f800ad10d81ca"
    },
    "8.3.7": {
        "renios.zip": "5b36af73640f2cb9ec68b5c2d90fc34ab2ac6832af45fd97c4c852e316ac779d",
        "sdk.tar.bz2": "13a221c1e2ac6730e7d369fef93153b79940fa8ae3ec3660abd94c67dea58f4e"
    },
    "8.4.1": {
        "renios.zip": "f631ccd21f6fdc22619882bf55d44653f402dfe832422d1eefa804cba1ee819f",
        "sdk.tar.bz2": "7e398814f242b3c4e51b29b9edb7369d1c71434dacdeb2e83445f11addd55076"
    },
    "8.5.0": {
        "renios.zip": "ecc771d15082900c5acacfeb32c287c95b9b08f54d7d9aff82629c148e4f19a6",
        "sdk.tar.bz2": "c7c3c04499749d9842ba666559cf8e2947264301a016fe6e937031d3b22b9db2"
    },
    "8.5.2": {
        "renios.zip": "288e6eee2b17257e00a04d595f483f37c6104efd77dc79d45e5aa48b08a1dfba",
        "sdk.tar.bz2": "cf9ed145e5b32521a4b2caddb4cd3073c64259ac51e1f7aab94a8a8ff72b55c4"
    },
    "8.5.3": {
        "renios.zip": "c4fae153e8276ed0faed5e84ea3e0b7c4bf337f0e3208e9130c6a41748a83b2b",
        "sdk.tar.bz2": "eb0a9be7f0fb13632fe25ceade9a8bed5a1b4d6b6e83bd19eeeb29e1a1bb4a45"
    },
    "8.6.0": {
        "renios.zip": "265e0f41698a1c4a1d1922412a31b70c640ec0f486e0914dd276479f8a27d65c",
        "sdk.tar.bz2": "5763c1d5f35de4e62e29df5387636e8bca681050c6523564db17bc09a48b3dd4"
    }
}
PREVIOUS_PREVIEW = {
    "renios.zip": "046ad6d8774389c62fe939a18de4c67e6646ba9b4d35a0c1a95e8ec3253ef504",
    "sdk.tar.bz2": "b3215982d6ce33446507b9a3f338c4dabd87b839484f01646087e2d85f143e38",
}
BUNDLE_ID = "io.renios.player"
ZIP_PACKAGE_ID = "B10000000000000000000001"
ZIP_PRODUCT_ID = "B10000000000000000000002"
ZIP_BUILD_ID = "B10000000000000000000003"


def digest(path):
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def get_archive(version, archive, allowed, cache):
    filename = cache / f"{version}-{archive}"
    if version == "8.5.3":
        upstream = f"https://github.com/renpy/renpy/releases/download/8.5.3.26051504/renpy-{version}-{archive}"
    else:
        upstream = f"https://www.renpy.org/dl/{version}/renpy-{version}-{archive}"
    if not filename.is_file():
        cache.mkdir(parents=True, exist_ok=True)
        partial = filename.with_suffix(".partial")
        try:
            subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error",
                            "--retry", "2", "--output", str(partial), upstream], check=True)
            if digest(partial) not in allowed:
                raise ValueError(f"Checksum mismatch for {upstream}")
            partial.replace(filename)
        finally:
            partial.unlink(missing_ok=True)
    checksum = digest(filename)
    if checksum not in allowed:
        raise ValueError(f"Checksum mismatch for {filename}")
    return filename, checksum


def insert_after(text, marker, addition):
    if text.count(marker) != 1:
        raise ValueError(f"Unexpected upstream project layout around {marker!r}")
    return text.replace(marker, marker + addition, 1)


def configure_project(project, version):
    config = project.read_text()
    major, minor = python_series(version).split(".")
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
        f'\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = ("$(inherited)", "RENIOS_SDL3={int(version == "8.6.0")}", '
        f'"RENIOS_PY2={int(major == "2")}", "RENIOS_PY_MINOR={minor}");\n'
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

    for index, name in enumerate(("reniOS.swift", "Library.swift", "Engine.swift", "APKTitle.swift", "Management.swift", "GameMetadata.swift", "CoverLookup.swift", "Insights.swift", "Settings.swift", "CoverBrowser.swift", "Runtime.c"), 4):
        file_type = "sourcecode.c.c" if name.endswith(".c") else "sourcecode.swift"
        reference = f"B100000000000000000000{index:02d}"
        build = f"B100000000000000000001{index:02d}"
        config = insert_after(config, "/* Begin PBXFileReference section */",
                              f'\n\t\t{reference} = {{isa = PBXFileReference; lastKnownFileType = {file_type}; path = {name}; sourceTree = "<group>"; }};')
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


def python_series(version):
    major, minor, _ = map(int, version.split("."))
    if major == 7:
        return "2.7"
    return "3.9" if minor <= 3 else "3.12"


def patch_legacy_drawable_resize(engine):
    core = engine / "display" / "core.py"
    source = core.read_text(encoding="utf-8")
    original = "                if renpy.display.draw.update(force=self.display_reset):"
    replacement = """                # Backport the iOS drawable-size check from Ren'Py 7.5.
                force_resize = self.display_reset
                if renpy.ios and not force_resize:
                    cached_drawable = getattr(renpy.display.draw, "drawable_size", None)
                    if cached_drawable is not None:
                        drawable = pygame.display.get_drawable_size()
                        force_resize = bool(drawable and min(drawable) > 0 and drawable != cached_drawable)

                if renpy.display.draw.update(force=force_resize):"""
    if source.count(original) != 1:
        raise ValueError("Unexpected Ren’Py 7.4.11 resize loop")
    core.write_text(source.replace(original, replacement), encoding="utf-8")
    for suffix in (".pyc", ".pyo"):
        core.with_suffix(suffix).unlink(missing_ok=True)


def configure_game_reload(engine):
    bootstrap = engine / "bootstrap.py"
    source = bootstrap.read_text(encoding="utf-8")
    source, count = re.subn(r"^    renpy\.import_all\(\).*?^    renpy\.(?:loader|importer)\.init_importer\(\)$",
                            lambda match: "    import renios_runtime\n    if not renios_runtime.initialized:\n"
                            + "".join("    " + line if line.strip() else line
                                      for line in match[0].splitlines(keepends=True))
                            + "\n        renios_runtime.initialized = True", source, flags=re.M | re.S)
    if count != 1:
        raise ValueError("Expected one Ren’Py importer startup block")

    cleanup = re.compile(r"(^        sys\.exit\(exit_status\)\n\n    finally:\n).*\Z", re.M | re.S)
    source, count = cleanup.subn(r"\1        renios_runtime.finish(renpy)\n", source)
    if count != 1:
        raise ValueError("Expected one Ren’Py shutdown block")
    # The host supplies the exact installed project path.
    source = source.replace("basedir = get_alternate_base(original_basedir)", "basedir = original_basedir")
    bootstrap.write_text(source, encoding="utf-8")

    main = engine / "main.py"
    source = main.read_text(encoding="utf-8")
    source, count = re.subn(r'^( +)log_clock\("Running init code\.?"\)$',
                            lambda match: match[0] + "\n" + match[1]
                            + "import renios_runtime\n" + match[1]
                            + "renios_runtime.record_metadata(renpy)",
                            source, flags=re.M)
    if count != 1:
        raise ValueError("Expected one Ren’Py game initialization checkpoint")
    main.write_text(source, encoding="utf-8")

    module = engine / "__init__.py"
    source = module.read_text(encoding="utf-8")
    # Keep the Objective-C class proxy out of the Python module backup.
    source = source.replace("if name in backup_blacklist:",
                            'if name in backup_blacklist or name == "renpy.audio.ioshw":')
    source = source.replace("        if mobile:\n            return\n",
                            "        if mobile and not ios:\n            return\n")
    source = source.replace("    if not mobile:\n        backup = Backup()",
                            "    if not mobile or ios:\n        backup = Backup()")
    source = source.replace('    if mobile:\n        raise Exception("Reloading is not supported on mobile platforms.")',
                            '    if mobile and not ios:\n        raise Exception("Reloading is not supported on mobile platforms.")')
    source = source.replace('    if not renpy.session.get("_keep_renderer", False):',
                            '    if renpy.display.draw is not None and not renpy.session.get("_keep_renderer", False):')
    module.write_text(source, encoding="utf-8")
    core = engine / "display" / "core.py"
    source = core.read_text(encoding="utf-8")
    quit_handler = re.compile(r"^( +)def quit_event\(self\)(?: *-> *None)?:[ \t]*$", re.M)

    def handle_confirmed_exit(match):
        indent = match[1] + "    "
        return (match[0] + "\n" + indent + "import renios_runtime\n"
                + indent + "if renios_runtime.consume_confirmed_exit():\n"
                + indent + "    renpy.exports.quit()")

    source, count = quit_handler.subn(handle_confirmed_exit, source)
    if count != 1:
        raise ValueError("Expected one Ren’Py quit event handler")
    core.write_text(source, encoding="utf-8")

    for patched in (bootstrap, main, module, core):
        for suffix in (".pyc", ".pyo"):
            patched.with_suffix(suffix).unlink(missing_ok=True)
        cache = patched.parent / "__pycache__"
        for compiled in cache.glob(f"{patched.stem}.*.pyc"):
            compiled.unlink()


def prepare_runtime(version, cache, build, *, host=True):
    candidates = [VERSIONS[version]]
    if version == "8.6.0":
        candidates.append(PREVIOUS_PREVIEW)
    files = {name: get_archive(version, name, {release[name] for release in candidates}, cache)
             for name in VERSIONS[version]}
    if {name: value[1] for name, value in files.items()} not in candidates:
        raise ValueError("The Ren’Py SDK and iOS pack belong to different release builds")
    archives = {name: value[0] for name, value in files.items()}
    build.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archives["renios.zip"]) as archive:
        if host:
            archive.extractall(build)
        else:
            prefix = "renios/prototype/"
            project = prefix + "prototype.xcodeproj/project.pbxproj"
            flags = re.findall(rb'"-l([^"]+)"', archive.read(project))
            required = {f"lib{flag.decode()}.a" for flag in flags}
            required -= {"libpython2.7.a", "libpython3.9.a", "libpython3.12.a"}
            required.add(f"libpython{python_series(version)}.a")
            archive.extractall(build, members=[
                item for item in archive.namelist()
                if item == project or (
                    item.startswith(prefix + "prebuilt/") and item.rsplit("/", 1)[-1] in required
                )
            ])
    prototype = build / "renios" / "prototype"
    prefix = f"renpy-{version}-sdk"
    python_dir = f"python{python_series(version)}"
    with tarfile.open(archives["sdk.tar.bz2"]) as archive:
        def needed(entry):
            path = Path(entry.name)
            if not path.parts or path.parts[0] != prefix:
                return False
            relative = path.parts[1:]
            return relative[:1] == ("renpy",) or relative[:2] == ("lib", python_dir) or relative in (("renpy.py",), ("LICENSE.txt",))

        archive.extractall(build, members=(entry for entry in archive if needed(entry)), filter="data")

    sdk = build / prefix
    base = prototype / "base"
    base.joinpath("lib").mkdir(parents=True)
    shutil.move(sdk / "renpy", base / "renpy")
    if version == "7.4.11":
        patch_legacy_drawable_resize(base / "renpy")
    shutil.move(sdk / "lib" / python_dir, base / "lib" / python_dir)
    shutil.move(sdk / "renpy.py", base / "renpy_entry.py")
    shutil.copyfile(sdk / "LICENSE.txt", base / "RenPy-LICENSE.txt")
    configure_game_reload(base / "renpy")
    shutil.copyfile(ROOT / "Scripts" / "engine_main.py", base / "renios_runtime.py")
    return prototype


def prepare(version, cache, legacy_versions=()):
    build = ROOT / ".build" / "project"
    if build.exists():
        shutil.rmtree(build)
    prototype = prepare_runtime(version, cache, build)
    base = prototype / "base"
    shutil.copytree(ROOT / "Demo", base / "Demo")
    installed = [*legacy_versions, version]
    legacy_namespaces = {engine: f"R{index:02d}" for index, engine in enumerate(legacy_versions, 1)}

    def prepare_legacy(engine):
        template = prepare_runtime(engine, cache, build / "engines" / engine, host=False)
        location = base / "Engines" / engine
        location.mkdir(parents=True)
        # The host passes this engine-specific base to its embedded interpreter.
        shutil.move(template / "base", location / "base")

    with ThreadPoolExecutor(max_workers=4) as pool:
        for engine, _ in zip(legacy_versions, pool.map(prepare_legacy, legacy_versions)):
            print(f"Prepared embedded Ren’Py {engine}", flush=True)
    for source in (ROOT / "App").iterdir():
        if source.is_file():
            shutil.copyfile(source, prototype / source.name)

    plist_path = prototype / "Info.plist"
    plist = plistlib.loads(plist_path.read_bytes())
    plist.update({
        "CFBundleDisplayName": "reniOS",
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
        "ReniosInstalledEngines": installed,
        "ReniosLegacyNamespaces": legacy_namespaces,
        "UISupportedInterfaceOrientations": [
            "UIInterfaceOrientationPortrait",
            "UIInterfaceOrientationLandscapeLeft",
            "UIInterfaceOrientationLandscapeRight",
        ],
        "UISupportedInterfaceOrientations~ipad": [
            "UIInterfaceOrientationPortrait",
            "UIInterfaceOrientationPortraitUpsideDown",
            "UIInterfaceOrientationLandscapeLeft",
            "UIInterfaceOrientationLandscapeRight",
        ],
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
    parser.add_argument("--legacy", nargs="+", choices=[v for v in VERSIONS if v != "8.6.0"])
    arguments = parser.parse_args()
    if arguments.legacy and arguments.engine != "8.6.0":
        parser.error("--legacy requires the SDL3 host")
    prepare(arguments.engine, arguments.cache, list(dict.fromkeys(arguments.legacy or [])))
