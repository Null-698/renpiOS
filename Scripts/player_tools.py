"""Session-scoped helpers for the player overlay (Python 2.7 and 3)."""
import math
import re

import renpy

try:
    scalar_types = (bool, int, long, float, str, unicode)
    text_type = unicode
except NameError:
    scalar_types = (bool, int, float, str)
    text_type = str

hooks = {}
mod_actions = {}
variable_names = []
screen_name = "_renios_workbench"


def reset():
    for originals in hooks.values():
        for cls, name, original in originals:
            setattr(cls, name, original)
    hooks.clear()
    mod_actions.clear()
    del variable_names[:]


def toggle(kind):
    if kind in hooks:
        for cls, name, original in hooks.pop(kind):
            setattr(cls, name, original)
    else:
        replacements = []
        if kind == "gallery":
            for key, cls in vars(renpy.store).items():
                if key.endswith(("__GalleryImage", "__GalleryButton")) and hasattr(cls, "check_unlock"):
                    replacements.append((cls, "check_unlock", lambda *args: True))
        elif kind == "replay":
            cls = renpy.store.Replay
            original_call = cls.__call__

            def play(action):
                # Construct a fresh action to preserve the author's replay scope.
                return original_call(cls(action.label, scope=action.scope, locked=False))

            replacements = [(cls, "get_sensitive", lambda action: renpy.exports.has_label(action.label)),
                            (cls, "__call__", play)]
        if not replacements:
            renpy.exports.notify("This engine has no compatible gallery.")
            return
        hooks[kind] = [(cls, name, getattr(cls, name)) for cls, name, method in replacements]
        for cls, name, method in replacements:
            setattr(cls, name, method)
    renpy.exports.restart_interaction()


def store_values():
    return renpy.python.store_dicts["store"]


def list_values(query):
    query = query.strip().lower()
    return [name for name in variable_names if query in name.lower() and type(store_values().get(name)) in scalar_types]


def printable(value):
    if isinstance(value, bytes) and not isinstance(value, text_type):
        return value.decode("utf-8", "replace")
    return text_type(value)


def apply_value(name, draft):
    values = store_values()
    current = values.get(name)
    kind = type(current)
    if name not in variable_names or kind not in scalar_types:
        return
    try:
        if kind is bool:
            if draft.lower() not in ("true", "false"):
                raise ValueError()
            updated = draft.lower() == "true"
        elif isinstance(current, bytes) and kind is not text_type:
            updated = draft.encode("utf-8")
        else:
            updated = kind(draft)
        if kind is float and (math.isnan(updated) or math.isinf(updated)):
            raise ValueError()
    except (ValueError, TypeError, OverflowError, UnicodeError):
        renpy.exports.notify("Enter a valid " + kind.__name__ + " value.")
        return
    values[name] = updated
    renpy.exports.notify("Updated " + name)
    return None


def mod_name(name):
    return isinstance(name, (str, text_type)) and bool(re.search(
        r"(^|[_ -])(mod(s|menu)?|cheat(s|menu)?|trainer|walkthrough)([_ -]|$)", name.lower()))


def button_title(node):
    children = list(node.visit() or [])
    for depth in range(3):
        nested = []
        for child in children[:12]:
            words = getattr(child, "text", None)
            if isinstance(words, (list, tuple)):
                for text in words:
                    if mod_name(text):
                        return text[:80]
            nested.extend(child.visit() or [])
        children = nested
    return None


def find_buttons():
    mod_actions.clear()
    # Prefer the actual game's button action, including its supplied arguments.
    seen = set()
    queue = [entry.displayable for entries in renpy.exports.scene_lists().layers.values() for entry in entries]
    while queue and len(seen) < 3000:
        node = queue.pop()
        if id(node) in seen:
            continue
        seen.add(id(node))
        action = getattr(node, "action", None)
        actions = action if isinstance(action, (list, tuple)) else [action]
        matched = False
        for part in actions:
            target = getattr(part, "screen", None)
            if mod_name(target):
                mod_actions[target] = action
                matched = True
        if action and not matched and isinstance(node, renpy.display.behavior.Button):
            title = button_title(node)
            if title:
                mod_actions[title] = action
        queue.extend(node.visit() or [])
    for name, variant in renpy.display.screen.screens:
        if not mod_name(name) or name in mod_actions or name.startswith("_"):
            continue
        screen = renpy.display.screen.get_screen_variant(name)
        if screen is None:
            continue
        params = getattr(screen.parameters, "parameters", None)
        if params or any(word in name.lower().split("_") for word in ("button", "overlay", "item")):
            continue
        mod_actions[name] = renpy.store.ToggleScreen(name)


def open_panel(mode):
    if renpy.exports.get_screen(screen_name):
        renpy.exports.hide_screen(screen_name)
        renpy.exports.restart_interaction()
        return
    if mode == "mods":
        find_buttons()
    else:
        values = store_values()
        variable_names[:] = sorted(name for name in values.ever_been_changed
                                   if not name.startswith("_") and type(values.get(name)) in scalar_types)
    renpy.exports.show_screen(screen_name, mode=mode)
    renpy.exports.restart_interaction()


def run_mod(name):
    action = mod_actions.get(name)
    if action is not None:
        renpy.exports.hide_screen(screen_name)
        renpy.display.behavior.run(action)
        renpy.exports.restart_interaction()


def hotkey(key):
    import pygame_sdl2 as pygame
    renpy.exports.hide_screen(screen_name)
    code = getattr(pygame, "K_" + key)
    for event in (pygame.KEYDOWN, pygame.KEYUP):
        pygame.event.post(pygame.event.Event(event, key=code, mod=0, unicode=key if len(key) == 1 else ""))
    renpy.exports.restart_interaction()
