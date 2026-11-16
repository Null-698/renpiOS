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
