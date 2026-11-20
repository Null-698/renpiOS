"""Per-launch player options for the Python 2 and Python 3 engine bundles."""
import errno
import itertools
import os
import socket
import struct

settings = {}
_originals = []


def replace(owner, name, value):
    owned = name in vars(owner)
    _originals.append((owner, name, getattr(owner, name), owned))
    setattr(owner, name, value)


def reset():
    for owner, name, old, owned in reversed(_originals):
        if owned:
            setattr(owner, name, old)
        else:
            delattr(owner, name)
    del _originals[:]
    settings.clear()


def begin(options):
    settings.update(options)
    for key, variable in (("memory", "RENPY_LESS_MEMORY"), ("refresh", "RENPY_LESS_UPDATES")):
        if options.get(key):
            os.environ[variable] = "1"
    if not options.get("network", True):
        def denied(*args, **kwargs):
            raise socket.error(errno.ENETUNREACH, "Game networking is disabled")
        def unreachable(*args, **kwargs):
            return errno.ENETUNREACH
        for name in ("connect", "connect_ex", "sendto", "sendmsg"):
            if hasattr(socket.socket, name):
                replace(socket.socket, name, unreachable if name == "connect_ex" else denied)
        for name in ("create_connection", "getaddrinfo", "gethostbyname", "gethostbyname_ex", "gethostbyaddr"):
            if hasattr(socket, name):
                replace(socket, name, denied)


def configure(renpy):
    config = renpy.config
    if settings.get("developer"):
        config.developer = True
    if settings.get("console"):
        config.console = True
    if settings.get("skip"):
        config.allow_skipping = True
    if settings.get("rollback"):
        config.rollback_enabled = True
        config.hard_rollback_limit = 100
        config.rollback_length = 128
    if settings.get("memory"):
        if hasattr(config, "image_cache_size_mb"):
            current = config.image_cache_size_mb
            config.image_cache_size_mb = min(current, 32) if current and current > 0 else 32
        if hasattr(config, "predict_statements"):
            config.predict_statements = 0
        if hasattr(config, "predict_screens"):
            config.predict_screens = False
    if settings.get("dialogue"):
        style = renpy.store.style
        style.say_window.background = None
        style.namebox.background = None
        for text_style in (style.say_label, style.say_dialogue):
            text_style.outlines = [(1, "#000", 0, 0)]
    if settings.get("unseen"):
        cls = type(renpy.game.preferences)
        original = cls.__getattribute__
        def get_preference(instance, key):
            if key == "skip_unseen":
                return True
            return original(instance, key)
        replace(cls, "__getattribute__", get_preference)
    level = settings.get("volume", 1.0)
    if level != 1.0:
        # Apply gain after the game's own channel and mixer levels, including on
        # older engines without a main mixer. Never write game preferences.
        sound = renpy.audio.audio.renpysound
        original_volume = sound.set_volume
        def channel_volume(channel, volume):
            return original_volume(channel, volume * level)
        replace(sound, "set_volume", channel_volume)
    if settings.get("chinese") and settings.get("fontDirectory"):
        config.searchpath.append(settings["fontDirectory"])
        install_fallback(renpy)


def cmap_checker(stream, face_index):
    """Return a glyph lookup for the Unicode cmap of an SFNT or collection."""
    def read_at(pos, size):
        stream.seek(pos)
        data = stream.read(size)
        if len(data) != size:
            raise ValueError("Incomplete font table")
        return data
    offset = 0
    if read_at(0, 4) == b"ttcf":
        offset = struct.unpack(">I", read_at(12 + 4 * face_index, 4))[0]
    count = struct.unpack(">H", read_at(offset + 4, 2))[0]
    for i in range(count):
        tag, _, start, size = struct.unpack(">4sIII", read_at(offset + 12 + i * 16, 16))
        if tag == b"cmap":
            break
    else:
        return None
    if size > 16 * 1024 * 1024:
        return None
    table = read_at(start, size)
    def u16(pos):
        return struct.unpack_from(">H", table, pos)[0]
    subtables = []
    for i in range(u16(2)):
        platform, encoding, pos = struct.unpack_from(">HHI", table, 4 + 8 * i)
        if platform == 0 or (platform == 3 and encoding in (1, 10)):
            fmt = u16(pos)
            if fmt in (4, 12):
                subtables.append((fmt, pos))
    if not subtables:
        return None

    def has(code):
        for fmt, pos in subtables:
            if fmt == 12:
                lo, hi = 0, struct.unpack_from(">I", table, pos + 12)[0]
                while lo < hi:
                    mid = (lo + hi) // 2
                    first, last, glyph = struct.unpack_from(">III", table, pos + 16 + 12 * mid)
                    if code < first:
                        hi = mid
                    elif code > last:
                        lo = mid + 1
                    else:
                        return glyph + code - first != 0
            elif code <= 65535:
                n = u16(pos + 6) // 2
                lo, hi = 0, n
                while lo < hi:
                    mid = (lo + hi) // 2
                    if u16(pos + 14 + mid * 2) < code:
                        lo = mid + 1
                    else:
                        hi = mid
                if lo < n:
                    first = u16(pos + 16 + 2 * n + lo * 2)
                    if code >= first:
                        delta = u16(pos + 16 + 4 * n + lo * 2)
                        rp = pos + 16 + 6 * n + lo * 2
                        distance = u16(rp)
                        glyph = u16(rp + distance + 2 * (code - first)) if distance else code
                        if glyph and ((glyph + delta) & 65535):
                            return True
        return False
    return has


def install_fallback(renpy):
    from renpy.text.text import TextSegment
    fallback = "renios-cjk.otf"
    coverage = {}
    original = TextSegment.subsegment
    def missing(font, ch):
        n = ord(ch)
        if not (0x3000 <= n <= 0x303f or 0x3400 <= n <= 0x9fff or
                0xf900 <= n <= 0xfaff or 0xff00 <= n <= 0xffef or 0x20000 <= n <= 0x323af):
            return False
        if font not in coverage:
            try:
                index, sep, filename = font.partition("@")
                with renpy.loader.load(filename if sep else font, directory="fonts") as stream:
                    coverage[font] = cmap_checker(stream, int(index) if sep else 0)
            except (AttributeError, ValueError, TypeError, IOError, struct.error):
                coverage[font] = None
        check = coverage[font]
        return check is not None and not check(n)

    def segments(segment, text):
        for part, run in original(segment, text):
            for substitute, chars in itertools.groupby(run, lambda ch: missing(part.font, ch)):
                target = part
                if substitute:
                    target = TextSegment(part)
                    target.font = fallback
                yield target, u"".join(chars)
    replace(TextSegment, "subsegment", segments)
