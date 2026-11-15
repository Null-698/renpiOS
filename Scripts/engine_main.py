"""Enter the bundled Ren'Py launcher while leaving the iOS host alive on quit."""
import os

__file__ = os.path.join(os.path.dirname(__file__), "renpy_entry.py")

try:
    with open(__file__, "rb") as entry:
        eval(compile(entry.read(), __file__, "exec"), globals())
except SystemExit as status:
    if status.code:
        raise RuntimeError("Ren'Py stopped with status {!r}".format(status.code))
