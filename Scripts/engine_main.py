"""Run a project in an initialized Ren'Py interpreter."""
import os
import sys
from types import ModuleType

initialized = False
entry = None
usable = True
result_keys = ("RENIOS_QUIT_CONFIRMED", "RENIOS_PROBE_ENGINE", "RENIOS_PROBE_SAVES_MATCH", "RENIOS_PROBE_PROJECT")


def finish(renpy):
    """Flush the current game and restore the engine's startup state."""
    global usable
    usable = False
    renpy.display.tts.tts(None)
    for callback in getattr(renpy.config, "python_exit_callbacks", ()):
        callback()
    renpy.session.pop("_keep_renderer", None)
    renpy.reload_all()
    # The renderer releases its GL resources. The pygame layer owns the
    # actual SDL window and must release it before the library becomes active.
    import pygame_sdl2
    pygame_sdl2.display.quit()
    renpy.session.clear()
    usable = True


def play():
    global entry
    if not usable:
        raise RuntimeError("Ren'Py did not finish closing the previous game.")

    path = os.path.dirname(sys.argv[0])
    project = os.path.realpath(sys.argv[1])
    probe = sys.argv.pop() == "1"
    session_path = list(sys.path)
    original_directory = os.getcwd()
    for key in result_keys:
        os.environ.pop(key, None)
    if probe:
        os.environ["RENIOS_PLAYBACK_PROBE"] = "1"
        os.environ["RENIOS_PROBE_SAVES"] = sys.argv[3]
    else:
        os.environ.pop("RENIOS_PLAYBACK_PROBE", None)
        os.environ.pop("RENIOS_PROBE_SAVES", None)

    diagnostic = None
    if probe:
        try:
            import faulthandler
            faulthandler.dump_traceback_later(20)
            diagnostic = faulthandler
        except (ImportError, AttributeError, RuntimeError):
            pass

    original_environment = dict(os.environ)
    original_modules = set(sys.modules)
    original_excepthook = sys.excepthook
    try:
        if entry is None:
            module = sys.modules["__main__"]
            module.__file__ = os.path.join(path, "renpy_entry.py")
            # The initial entry script calls main() itself. Keep this module
            # around for subsequent calls and for older engines' __main__ imports.
            with open(module.__file__, "rb") as source:
                program = compile(source.read(), module.__file__, "exec")
            try:
                eval(program, module.__dict__)
            finally:
                if hasattr(module, "main"):
                    entry = module.main
        else:
            entry()
    except SystemExit as status:
        if status.code:
            raise RuntimeError("Ren'Py stopped with status {!r}".format(status.code))
    finally:
        if diagnostic is not None:
            diagnostic.cancel_dump_traceback_later()
        sys.path[:] = session_path
        sys.excepthook = original_excepthook
        os.chdir(original_directory)
        for key in set(os.environ) - set(original_environment) - set(result_keys):
            del os.environ[key]
        for key, value in original_environment.items():
            if os.environ.get(key) != value:
                os.environ[key] = value
        for name in set(sys.modules) - original_modules:
            module = sys.modules.get(name)
            if not isinstance(module, ModuleType):
                continue
            attributes = vars(module)
            paths = list(attributes.get("__path__") or ())
            filename = attributes.get("__file__")
            if filename:
                paths.append(filename)
            loader = attributes.get("__loader__")
            game_loader = type(loader).__module__ in ("renpy.loader", "renpy.importer")
            if game_loader or any(p.startswith("$game/") or os.path.realpath(p).startswith(project + os.sep)
                                  for p in paths):
                sys.modules.pop(name, None)


def record_metadata(renpy):
    """Read the values evaluated by Ren'Py, including projects stored in RPA archives."""
    import json

    root = renpy.config.basedir
    if os.path.realpath(root) != os.path.realpath(sys.argv[1]):
        return

    def write(name, value):
        path = os.path.join(root, name)
        temp = path + ".tmp"
        try:
            with open(temp, "wb") as output:
                output.write(value)
            os.rename(temp, path)
        finally:
            if os.path.isfile(temp):
                os.remove(temp)

    def text(value):
        if isinstance(value, bytes):
            return value.decode("utf-8", "replace")
        # Python 2 games also return unicode title and save strings.
        if isinstance(value, type(u"")):
            return value
        return None

    try:
        build = getattr(renpy.store, "build", None)
        write(".renios-runtime.json", json.dumps({
            "title": text(getattr(renpy.config, "name", None)),
            "saveDirectory": text(getattr(renpy.config, "save_directory", None)),
            "buildName": text(getattr(build, "name", None)),
            "developer": text(getattr(renpy.config, "developer", None)),
        }, ensure_ascii=True).encode("utf-8"))

        cached = os.path.join(root, ".renios-archive-cover")
        if os.path.isfile(cached):
            return
        with open(os.path.join(root, "novel.json"), "rb") as metadata:
            if json.load(metadata).get("localCover"):
                return

        gui = getattr(renpy.store, "gui", None)
        background = text(getattr(gui, "main_menu_background", None))
        icon = text(getattr(renpy.config, "window_icon", None))
        cover_names = ("cover", "boxart", "box_art", "poster", "keyart", "key_art", "game_cover", "cover_art")
        menu_names = ("main_menu", "mainmenu", "title_screen", "title_background", "menubg", "menu_background")
        candidates = []
        for directory, filename in renpy.loader.listdirfiles(common=False):
            name = text(filename)
            if not name or not name.lower().endswith((".png", ".jpg", ".jpeg", ".webp", ".avif")):
                continue
            stem = os.path.splitext(name.rsplit("/", 1)[-1])[0].lower()
            if stem in cover_names:
                rank = 0
            elif name == background:
                rank = 1
            elif stem in menu_names:
                rank = 2
            elif name == icon or stem in ("icon", "window_icon", "app_icon"):
                rank = 3
            else:
                continue
            candidates.append((rank, len(name), name))
        for _, _, name in sorted(candidates)[:24]:
            try:
                with renpy.loader.load(name) as asset:
                    data = asset.read(16 * 1024 * 1024 + 1)
                if 16 <= len(data) <= 16 * 1024 * 1024:
                    is_image = (data[:8] == b"\x89PNG\r\n\x1a\n" or data[:2] == b"\xff\xd8"
                                or data[:4] == b"RIFF" and data[8:12] == b"WEBP"
                                or data[4:8] == b"ftyp" and data[8:12] in (b"avif", b"avis"))
                    if is_image:
                        write(".renios-archive-cover", data)
                        break
            except Exception:
                continue
    except Exception as error:
        # Optional metadata should never interrupt playback.
        sys.stderr.write("reniOS metadata: {}\n".format(error))
