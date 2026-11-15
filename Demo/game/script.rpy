define narrator = Character(None)

init python:
    import os

label start:
    scene expression Solid("#232741")
    if os.environ.get("RENIOS_KEYBOARD_PROBE") == "1":
        $ os.environ["RENIOS_PROBE_SAVES_MATCH"] = str(int(os.path.realpath(renpy.config.savedir) == os.path.realpath(os.environ.get("RENIOS_PROBE_SAVES", ""))))
        $ os.environ["RENIOS_PROBE_ENGINE"] = "{}.{}.{}".format(*tuple(renpy.version_tuple)[:3])
        show text "The Observatory" at truecenter
        $ probe_name = renpy.input("Keyboard check", length=24)
        return

    "You reach the observatory just as the last light leaves the sky."
    "On the desk, a brass dial ticks without moving."
    $ reader_name = renpy.input("Who should sign the visitor’s book?", length=24).strip() or "Traveler"
    "[reader_name], the keeper left you a choice."

    menu:
        "Open the dome":
            "The roof rolls back. For a moment, every star seems close enough to touch."
        "Listen to the dial":
            "The ticking stops. From somewhere below, a clock begins to answer."

    return
