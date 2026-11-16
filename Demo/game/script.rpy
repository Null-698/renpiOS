define narrator = Character(None)

init python:
    import os

label start:
    scene expression Solid("#232741")
    if os.environ.get("RENIOS_PLAYBACK_PROBE") == "1":
        $ os.environ["RENIOS_PROBE_SAVES_MATCH"] = str(int(os.path.realpath(renpy.config.savedir) == os.path.realpath(os.environ.get("RENIOS_PROBE_SAVES", ""))))
        show text "The Observatory" at truecenter
        $ os.environ["RENIOS_PROBE_PROJECT"] = os.path.basename(renpy.config.basedir)
        $ renpy.pause(0.2, hard=True)
        $ os.environ["RENIOS_PROBE_ENGINE"] = "{}.{}.{}".format(*tuple(renpy.version_tuple)[:3])
        "Playback check."
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
