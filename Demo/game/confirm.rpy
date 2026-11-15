init python:
    def observatory_confirm_probe():
        import os
        os.environ["RENIOS_QUIT_CONFIRMED"] = "1"

screen confirm(message, yes_action, no_action):
    modal True
    zorder 200
    add Solid("#0009")

    frame:
        align (0.5, 0.5)
        padding (28, 22)
        background Solid("#232741")

        vbox:
            spacing 18
            text message

            hbox:
                spacing 24
                textbutton _("Yes") action yes_action
                textbutton _("No") action no_action

    key "game_menu" action no_action

    if os.environ.get("RENIOS_KEYBOARD_PROBE") == "1":
        timer 0.2 action [Function(observatory_confirm_probe, _update_screens=False), yes_action]
