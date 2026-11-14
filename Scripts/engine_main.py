"""Enter the bundled Ren'Py launcher while leaving the iOS host alive on quit."""

from pathlib import Path

entry = Path(__file__).with_name("renpy_entry.py")
__file__ = str(entry)

try:
    exec(compile(entry.read_bytes(), __file__, "exec"), globals())
except SystemExit as status:
    if status.code:
        raise RuntimeError("Ren'Py stopped with status {!r}".format(status.code)) from None
