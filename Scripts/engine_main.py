"""Run a project in an initialized Ren'Py interpreter."""
import os
import sys
import playback_settings
from types import ModuleType

initialized = False
entry = None
usable = True

LAYOUT_VARIANTS = {"desktop": "large pc touch", "phone": "small phone touch ios mobile",
                   "tablet": "medium tablet touch ios mobile"}


def finish(renpy):
    """Flush the current game and restore the engine's startup state."""
    global usable
    usable = False
    if "renios_tools" in sys.modules:
        sys.modules["renios_tools"].reset()
    playback_settings.reset()
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
    session_path = list(sys.path)
    original_directory = os.getcwd()
    original_environment = dict(os.environ)
    original_modules = set(sys.modules)
    original_excepthook = sys.excepthook
    try:
        # Ren'Py chooses screen variants before running the game's init scripts.
        # The environment snapshot below also isolates back-to-back launches.
        import json
        try:
            with open(os.path.join(project, ".renios-display.json"), "rb") as source:
                options = json.load(source)
        except (IOError, ValueError):
            options = {}
        playback_settings.begin(options)
        variants = LAYOUT_VARIANTS.get(options.get("layout"))
        if variants:
            os.environ["RENPY_VARIANT"] = variants
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
        playback_settings.reset()
        sys.path[:] = session_path
        sys.excepthook = original_excepthook
        os.chdir(original_directory)
        for key in set(os.environ) - set(original_environment):
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


def consume_confirmed_exit():
    """Consume the launcher’s one-shot confirmation for the current game."""
    marker = os.path.join(sys.argv[1], ".renios-confirmed-exit")
    try:
        os.remove(marker)
    except OSError:
        return False
    return True


def configure_display(renpy):
    """Apply the optional player display preference before renderer setup."""
    import json
    path = os.path.join(sys.argv[1], ".renios-display.json")
    try:
        with open(path, "rb") as source:
            settings = json.load(source)
        if settings.get("fill", False):
            renpy.config.adjust_view_size = lambda width, height: (width, height)
    except (OSError, ValueError, TypeError):
        pass


def install_layout_control(renpy, root):
    import time
    request = os.path.join(root, ".renios-layout-request")
    tools_request = os.path.join(root, ".renios-tools-request")
    last_check = [0]
    clock = getattr(time, "monotonic", time.time)

    def poll():
        now = clock()
        if 0 <= now - last_check[0] < 0.25:
            return
        last_check[0] = now
        import renios_tools
        renios_tools.tick()
        if os.path.isfile(tools_request):
            try:
                with open(tools_request, "rb") as source:
                    request_data = source.read(65536).decode("utf-8")
                os.remove(tools_request)
                renios_tools.dispatch(tools_request, request_data)
            except renpy.game.CONTROL_EXCEPTIONS:
                raise
            except Exception as error:
                sys.stderr.write("reniOS game tools: {}\n".format(error))
                renpy.exports.notify("Could not open game tools.")
        if not os.path.isfile(request):
            return
        try:
            with open(request, "rb") as source:
                profile = source.read(32).decode("ascii")
            os.remove(request)
            if profile == "device":
                os.environ.pop("RENPY_VARIANT", None)
            elif profile in LAYOUT_VARIANTS:
                os.environ["RENPY_VARIANT"] = LAYOUT_VARIANTS[profile]
            else:
                return
            renpy.main.choose_variants()
            screens = renpy.display.screen
            screens.predict_cache.clear()
            for entries in renpy.exports.scene_lists().layers.values():
                for entry in entries:
                    screen = entry.displayable
                    if isinstance(screen, screens.ScreenDisplayable):
                        variant = screens.get_screen_variant(screen.screen_name[0])
                        if variant is not None:
                            screen.screen = variant
                            screen.cache.clear()
                            screen.use_cache.clear()
            rebuild = getattr(getattr(renpy.store, "gui", None), "rebuild", None)
            if rebuild:
                rebuild()
            renpy.exports.restart_interaction()
        except Exception as error:
            sys.stderr.write("reniOS live layout: {}\n".format(error))

    callbacks = renpy.config.periodic_callbacks
    callbacks[:] = [callback for callback in callbacks if not getattr(callback, "_renios_layout", False)]
    poll._renios_layout = True
    callbacks.append(poll)


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

    configure_display(renpy)
    install_layout_control(renpy, root)
    try:
        build = getattr(renpy.store, "build", None)
        active_mods = False
        mod_state = os.path.join(root, "game", ".renios-mod-state.json")
        if os.path.isfile(mod_state):
            with open(mod_state, "rb") as state:
                active_mods = bool(json.load(state))
        else:
            active_mods = os.path.isdir(os.path.join(root, ".mod", "original"))
        write(".renios-runtime.json", json.dumps({
            "title": text(getattr(renpy.config, "name", None)),
            "version": text(getattr(renpy.config, "version", None)),
            "modsActive": active_mods,
            "saveDirectory": text(getattr(renpy.config, "save_directory", None)),
            "buildName": text(getattr(build, "name", None)),
            "developer": text(getattr(renpy.config, "developer", None)),
        }, ensure_ascii=True).encode("utf-8"))

        cached = os.path.join(root, ".renios-archive-cover")
        if os.path.isfile(cached):
            return
        icon_names = ("icon", "window_icon", "app_icon")
        with open(os.path.join(root, "novel.json"), "rb") as metadata:
            local = json.load(metadata).get("localCover")
            if local and os.path.splitext(local.rsplit("/", 1)[-1])[0].lower() not in icon_names:
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
            elif not local and (name == icon or stem in icon_names):
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
