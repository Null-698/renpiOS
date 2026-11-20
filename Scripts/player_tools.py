"""Runtime services for the native game workbench. Supports Python 2 and 3."""
from collections import deque
import fnmatch
import keyword
import json
import math
import os
import re
import renpy

try:
    strings = (str, unicode)
    numbers = (int, long, float)
    text_type = unicode
except NameError:
    strings = (str,)
    numbers = (int, float)
    text_type = str

enabled = set()
originals = []
mod_actions = {}
paths = {}
watched = set()
frozen = {}
baseline = {}
undo = []
replays = {}
MISSING = object()
linked = []
LIMIT = 40000


def reset():
    for obj, name, original, owned in reversed(originals):
        if owned:
            setattr(obj, name, original)
        else:
            delattr(obj, name)
    del originals[:]
    del undo[:]
    del linked[:]
    for collection in (enabled, mod_actions, paths, watched, frozen, baseline, replays):
        collection.clear()


def patch(obj, name, replacement):
    if hasattr(obj, name):
        originals.append((obj, name, getattr(obj, name), name in vars(obj)))
        setattr(obj, name, replacement)


def plain(value):
    if isinstance(value, bytes) and not isinstance(value, text_type):
        return value.decode("utf-8", "replace")
    return text_type(value)


def media_context():
    screen = renpy.display.screen.current_screen()
    name = getattr(screen, "screen_name", ())
    if isinstance(name, (tuple, list)):
        name = " ".join(name)
    name = (name or "").lower()
    return (("gallery" in enabled and any(k in name for k in ("gallery", "album", "bonus", "extras", "cg_")))
            or ("replays" in enabled and any(k in name for k in ("replay", "scene", "memories", "gallery"))))


class AccessList(list):
    def __contains__(self, item):
        return True


class AccessSet(set):
    def __contains__(self, item):
        return True


class AccessMap(dict):
    def __contains__(self, item):
        return True

    def __missing__(self, key):
        return True

    def get(self, key, default=None):
        return self[key]


def access(value):
    if value is None or type(value) is bool:
        return True
    if isinstance(value, list):
        return AccessList(access(x) if type(x) is bool else x for x in value)
    if isinstance(value, (set, frozenset)):
        return AccessSet(value)
    if isinstance(value, dict):
        return AccessMap((k, True if type(v) is bool else v) for k, v in value.items())
    if type(value) in numbers and value == 0:
        return type(value)(1)
    return value


def install_hooks():
    if originals:
        return
    store = renpy.store
    for key, cls in list(vars(store).items()):
        if key.endswith(("__GalleryImage", "__GalleryButton")) and hasattr(cls, "check_unlock"):
            def wrap(original):
                def check(self, *args):
                    return "gallery" in enabled or original(self, *args)
                return check
            patch(cls, "check_unlock", wrap(cls.check_unlock))
    cls = store.Replay
    old_sensitive, old_call = cls.get_sensitive, cls.__call__
    patch(cls, "get_sensitive", lambda action: renpy.exports.has_label(action.label) if "replays" in enabled else old_sensitive(action))
    def play(action):
        if "replays" in enabled and action.locked:
            action = cls(action.label, scope=action.scope, locked=False)
        return old_call(action)
    patch(cls, "__call__", play)
    # The public store and the exports module can hold different function references.
    for api in (renpy.exports, getattr(store, "renpy", None)):
        if api is None:
            continue
        for name in ("seen_label", "seen_image", "seen_audio"):
            if any(obj is api and key == name for obj, key, _, _ in originals):
                continue
            if hasattr(api, name):
                def wrap_seen(original, category):
                    def seen(*args, **kwargs):
                        return True if category in enabled or media_context() else original(*args, **kwargs)
                    return seen
                patch(api, name, wrap_seen(getattr(api, name), "replays" if name == "seen_label" else "gallery"))
    cls = type(store.persistent)
    original = cls.__getattribute__
    def read(self, key):
        if not enabled or key.startswith("_"):
            return original(self, key)
        name = key.lower()
        named_gate = (("gallery" in enabled and any(token in name for token in ("gallery", "unlocked_cg", "seen_cg")))
                      or ("replays" in enabled and "replay" in name))
        if not named_gate and not media_context():
            return original(self, key)
        try:
            value = original(self, key)
        except AttributeError:
            return not ("locked" in name and "unlock" not in name)
        if type(value) is bool and "locked" in name and "unlock" not in name:
            return False
        return access(value)
    patch(cls, "__getattribute__", read)


def mod_title(value):
    if not isinstance(value, strings):
        return None
    title = re.sub(r"\{[^}]*\}", "", value).strip()
    name = re.sub(r"([a-z])([A-Z])", r"\1 \2", title)
    if re.search(r"(?:^|[^a-z]|z)(?:mods?|modmenu|cheats?|trainer|walkthrough)(?:[^a-z]|$)", name.lower()):
        return title[:100]


def children(node):
    try:
        return [x for x in node.visit() if x is not None]
    except (AttributeError, TypeError):
        return []


def focus_targets():
    targets = []
    for focus in renpy.display.focus.focus_list:
        node = focus.widget
        action = getattr(node, "action", None) or getattr(node, "clicked", None)
        if not action or focus.x is None or not focus.w or not focus.h:
            continue
        rect = tuple(int(n) for n in (focus.x, focus.y, focus.w, focus.h))
        if rect[2] <= 0 or rect[3] <= 0:
            continue
        owner = getattr(focus, "screen", None)
        signature = (getattr(owner, "screen_name", None), getattr(node, "id", None),
                     type(action).__name__, getattr(action, "screen", None))
        targets.append((rect, signature, action))
    return targets


def link_button(rect, signature):
    linked[:] = [(rect, signature)]
    renpy.exports.hide_screen("_renios_link_button")
    renpy.exports.notify("Button linked for this session.")
    renpy.exports.restart_interaction()


def find_buttons():
    mod_actions.clear()
    tree = getattr(renpy.game.interface, "old_scene", {})
    queue = deque(list(tree.values()) + [e.displayable for entries in renpy.exports.scene_lists().layers.values() for e in entries])
    queue.extend(f.widget for f in renpy.display.focus.focus_list)
    seen = set()
    while queue and len(seen) < 20000:
        node = queue.popleft()
        if node is None or id(node) in seen:
            continue
        seen.add(id(node))
        kids = children(node)
        queue.extend(kids)
        action = getattr(node, "action", None) or getattr(node, "clicked", None)
        if not action:
            continue
        parts = action if isinstance(action, (list, tuple)) else [action]
        title = None
        for part in parts:
            if isinstance(part, renpy.store.Replay):
                replays[part.label] = part
            for field in ("screen", "label", "__name__"):
                title = title or mod_title(getattr(part, field, None))
        if isinstance(node, renpy.display.behavior.Button):
            title = title or mod_title(getattr(node, "alt", None))
            branch = deque(kids)
            visited = set()
            while branch and not title and len(visited) < 160:
                child = branch.popleft()
                if id(child) in visited:
                    continue
                visited.add(id(child))
                words = getattr(child, "text", ())
                if isinstance(words, strings):
                    words = [words]
                if isinstance(words, (list, tuple)):
                    title = mod_title("".join(plain(w) for w in words if isinstance(w, strings)))
                branch.extend(children(child))
        if title:
            mod_actions[title] = action
    visible = sorted(mod_actions, key=lambda title: (title.lower() != "mod", title.lower()))
    for name, _ in renpy.display.screen.screens:
        if not mod_title(name) or name.startswith("_") or name in mod_actions:
            continue
        screen = renpy.display.screen.get_screen_variant(name)
        if screen and not getattr(screen.parameters, "parameters", None) and not re.search("button|overlay|item", name, re.I):
            mod_actions[name] = renpy.store.ToggleScreen(name)

    if linked:
        old, signature = linked[0]
        cx, cy = old[0] + old[2] / 2.0, old[1] + old[3] / 2.0
        for rect, candidate, action in focus_targets():
            x, y, w, h = rect
            if candidate == signature and x <= cx <= x + w and y <= cy <= y + h:
                mod_actions["Linked button"] = action
                return "Linked button"
    return next(iter(visible or sorted(mod_actions)), None)


def leaf(value):
    return type(value) in numbers + (bool, str, text_type)


class AttributeFields(object):
    def __init__(self, instance):
        self.instance = instance

    def __getitem__(self, key):
        if key not in vars(self.instance):
            raise KeyError(key)
        return getattr(self.instance, key)

    def __setitem__(self, key, value):
        setattr(self.instance, key, value)


def fields(value):
    return value if isinstance(value, (list, dict)) else AttributeFields(value)


def index_values():
    paths.clear()
    stores = renpy.python.store_dicts
    queue = deque()
    for store in sorted(stores):
        if store != "store" and (not store.startswith("store.") or
                any(part.startswith("_") for part in store.split(".")) or stores[store].get("_constant")):
            continue
        prefix = "" if store == "store" else store[6:] + "."
        for key, value in list(stores[store].items()):
            if isinstance(key, strings) and not key.startswith("_"):
                queue.append((prefix + key, (store, key), value))
    seen = set()
    count = 0
    limited = False
    while queue and count < LIMIT:
        name, path, value = queue.popleft()
        count += 1
        if leaf(value):
            paths[name] = path
            continue
        if id(value) in seen:
            continue
        seen.add(id(value))
        if isinstance(value, list):
            items = enumerate(value)
        elif isinstance(value, dict):
            items = value.items()
        elif (value is getattr(renpy.store, "persistent", None) and value is not None or
              (type(value).__module__ or "").split(".")[0] == "store" and not isinstance(value, type)):
            items = getattr(value, "__dict__", {}).items()
        else:
            continue
        for key, child in items:
            if len(queue) + count >= LIMIT:
                limited = True
                break
            if isinstance(key, strings):
                if key.startswith("_"):
                    continue
                suffix = "[" + repr(key) + "]" if isinstance(value, dict) else "." + plain(key)
            elif isinstance(key, numbers) and not isinstance(key, float):
                suffix = "[" + str(key) + "]"
            else:
                continue
            queue.append((name + suffix, path + (key,), child))
    return bool(queue) or limited


def slot(name):
    path = paths[name]
    value = renpy.python.store_dicts[path[0]]
    for key in path[1:-1]:
        value = fields(value)[key]
    return fields(value), path[-1]


def converted(draft, kind, original=None):
    if kind == "Original":
        dest = type(original)
    else:
        dest = {"Integer": int, "Decimal": float, "Boolean": bool, "Text": text_type}[kind]
    if dest is bool:
        if draft.lower() not in ("true", "false"):
            raise ValueError("Choose true or false.")
        return draft.lower() == "true"
    if dest is bytes and dest is not text_type:
        return draft.encode("utf-8")
    value = dest(draft)
    if isinstance(value, float) and (math.isnan(value) or math.isinf(value)):
        raise ValueError("Enter a finite number.")
    return value


def tick():
    for name, expected in list(frozen.items()):
        try:
            obj, key = slot(name)
            if type(obj[key]) is not type(expected):
                frozen.pop(name)
            elif obj[key] != expected:
                obj[key] = expected
        except (KeyError, IndexError, TypeError, AttributeError):
            frozen.pop(name, None)


def row(name, value="", kind=""):
    return dict(name=name, value=value, kind=kind, watched=name in watched, frozen=name in frozen)


def process(req):
    section = req.get("section", "values")
    action = req.get("action", "list")
    key = req.get("key", "")
    if action == "toggle" and section in ("gallery", "replays"):
        install_hooks()
        if section in enabled:
            enabled.remove(section)
        else:
            enabled.add(section)
        renpy.exports.restart_interaction()
    if section == "values":
        limited = index_values()
        if action == "snapshot":
            baseline.clear()
        if action == "create":
            values = renpy.python.store_dicts["store"]
            if not re.match(r"^[a-zA-Z][a-zA-Z0-9_]*\Z", key) or keyword.iskeyword(key) or key in values:
                raise ValueError("Choose an unused game variable name starting with a letter.")
            draft = req["draft"]
            try:
                new = json.loads(draft)
            except ValueError:
                new = draft
            if not leaf(new):
                new = draft
            if isinstance(new, float) and (math.isnan(new) or math.isinf(new)):
                raise ValueError("Enter a finite number.")
            values[key] = new
            paths[key] = ("store", key)
            undo.append((key, MISSING, new))
            del undo[:-50]
        if action == "undo" and undo:
            name, old, new = undo[-1]
            obj, k = slot(name)
            if type(obj[k]) is not type(new) or obj[k] != new:
                raise ValueError("The game changed this value after your edit.")
            if old is MISSING:
                del obj[k]
                paths.pop(name)
                frozen.pop(name, None)
                watched.discard(name)
                baseline.pop(name, None)
            else:
                obj[k] = old
            undo.pop()
            if name in frozen:
                frozen[name] = old
        if action in ("watch", "freeze", "edit"):
            obj, k = slot(key)
            old = obj[k]
            if not leaf(old):
                raise ValueError("The value type changed.")
            if action == "watch":
                watched.symmetric_difference_update([key])
            elif action == "freeze":
                if key in frozen:
                    del frozen[key]
                else:
                    frozen[key] = old
            else:
                new = converted(req["draft"], req.get("valueType", "Original"), old)
                if type(new) is not type(old) or new != old:
                    undo.append((key, old, new))
                    del undo[:-50]
                    obj[k] = new
                    if key in frozen:
                        frozen[key] = new
        names = sorted(paths, key=lambda x: x.lower())
    elif section == "mods":
        find_buttons()
        names = sorted(mod_actions)
    elif section == "gallery":
        names = sorted(" ".join(n) if isinstance(n, tuple) else n for n in renpy.exports.list_images())
    elif section == "replays":
        find_buttons()
        names = sorted(set(replays) | set(n for n in renpy.exports.get_all_labels()
                       if not n.startswith("_") and re.search(r"replay|(?:^|_)scene(?:_|\d)|memories", n, re.I)))
    else:
        raise ValueError("Unknown section.")
    query = req.get("query", "").lower()
    mode = req.get("filter", "All")
    offset = max(0, int(req.get("offset", 0)))
    rows = []
    total = 0
    for name in names:
        if section == "values":
            obj, k = slot(name)
            value = obj[k]
            changed = name in baseline and (type(baseline[name]) is not type(value) or baseline[name] != value)
            baseline.setdefault(name, value)
            if mode == "Watching" and name not in watched or mode == "Changed" and not changed or mode == "Frozen" and name not in frozen:
                continue
            if mode in ("Increased", "Decreased"):
                old = baseline[name]
                if type(old) not in numbers or type(value) not in numbers:
                    continue
                if mode == "Increased" and value <= old or mode == "Decreased" and value >= old:
                    continue
            scope = req.get("scope", "Name or value")
            terms = []
            if scope != "Value":
                terms.append(name.lower())
            if scope != "Name":
                terms.append(plain(value).lower())
            wildcard = "*" in query or "?" in query
            if query and not any(fnmatch.fnmatchcase(term, query) if wildcard else query in term for term in terms):
                continue
            if not offset <= total < offset + 40:
                total += 1
                continue
            entry = row(name, plain(value)[:2048], type(value).__name__)
            entry["truncated"] = len(plain(value)) > 2048
        else:
            if query not in name.lower():
                continue
            entry = row(name)
        if offset <= total < offset + 40:
            rows.append(entry)
        total += 1
    return dict(rows=rows, total=total, enabled=section in enabled, canUndo=bool(undo),
                limited=section == "values" and limited)


def dispatch(path, raw):
    req = json.loads(raw)
    action = req.get("action")
    key = req.get("key", "")
    section = req.get("section")
    launch = None
    try:
        if action == "activate" and section == "mods":
            key = find_buttons()
            result = dict(rows=[], total=len(mod_actions), enabled=False, canUndo=False, activated=key is not None)
            if key is not None:
                launch = lambda: renpy.display.behavior.run(mod_actions[key])
        else:
            result = process(req)
        if action == "link" and section == "mods":
            targets = [(rect, signature) for rect, signature, _ in focus_targets()]
            if not targets:
                raise ValueError("No tappable game buttons in this scene.")
            launch = lambda: renpy.exports.show_screen("_renios_link_button", targets=targets)
        if action == "open":
            if section == "mods" and key in mod_actions:
                launch = lambda: renpy.display.behavior.run(mod_actions[key])
            elif section == "gallery" and renpy.exports.has_image(key):
                launch = lambda: renpy.exports.show_screen("_renios_image_preview", asset=key)
            elif section == "replays" and renpy.exports.has_label(key):
                scope = getattr(replays.get(key), "scope", {})
                launch = lambda: renpy.exports.invoke_in_new_context(renpy.exports.call_replay, key, scope)
            else:
                raise ValueError("This item is no longer available.")
    except Exception as error:
        result = dict(rows=[], total=0, enabled=False, canUndo=False, error=plain(error))
    result["id"] = req["id"]
    temp = path + ".reply.tmp"
    with open(temp, "wb") as output:
        output.write(json.dumps(result, ensure_ascii=True).encode("ascii"))
    os.rename(temp, path + ".reply")
    if launch:
        rv = launch()
        if action in ("open", "activate") and section == "mods" and rv is not None:
            renpy.exports.end_interaction(rv)
        renpy.exports.restart_interaction()
