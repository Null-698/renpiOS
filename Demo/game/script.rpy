define narrator = Character(None)

label start:
    scene expression Solid("#232741")
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
