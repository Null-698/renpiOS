init python:
    import renios_tools as _renios_tools

style renios_tool_button is default:
    background Solid("#303949")
    hover_background Solid("#455672")
    padding (12, 6)

style renios_tool_button_text is default:
    color "#f4f5fa"
    size max(16, int(config.screen_height * .038))

style renios_tool_text is default:
    color "#f4f5fa"
    size max(16, int(config.screen_height * .038))

screen _renios_workbench(mode="tools"):
    modal True
    zorder 19000
    default section = "home"
    default page = 0
    default query = ""
    default editing = None
    default draft = ""
    add Solid("#0009")
    frame:
        align (.5, .5)
        xsize int(config.screen_width * .84)
        ysize int(config.screen_height * .86)
        background Solid("#18202ff9")
        padding (20, 14)
        vbox:
            style_prefix "renios_tool"
            spacing 8
            hbox:
                xfill True
                text ("Mod Buttons" if mode == "mods" else "Game Tools") bold True
                textbutton "Done" xalign 1.0 action Hide("_renios_workbench")
            if editing is not None:
                text ("Search values" if editing == "@search" else editing) substitute False
                input value ScreenVariableInputValue("draft") length 512 color "#ffffff"
                hbox:
                    spacing 8
                    if editing == "@search":
                        textbutton "Search" action [SetScreenVariable("query", draft), SetScreenVariable("page", 0), SetScreenVariable("editing", None)]
                    else:
                        textbutton "Apply" action Function(_renios_tools.apply_value, editing, draft)
                    textbutton "Back" action SetScreenVariable("editing", None)
            elif mode == "mods":
                viewport:
                    draggable True
                    mousewheel True
                    vbox:
                        spacing 6
                        for name in sorted(_renios_tools.mod_actions):
                            textbutton name.replace("_", " ") action Function(_renios_tools.run_mod, name)
                        if not _renios_tools.mod_actions:
                            text "No mod menu detected. Try the shortcut listed by the mod."
                        hbox:
                            spacing 6
                            for shortcut in ("m", "F1", "F2", "F3", "F4"):
                                textbutton shortcut.upper() action Function(_renios_tools.hotkey, shortcut)
            elif section == "home":
                textbutton ("Gallery access: On" if "gallery" in _renios_tools.hooks else "Gallery access: Off") action Function(_renios_tools.toggle, "gallery")
                textbutton ("Replay access: On" if "replay" in _renios_tools.hooks else "Replay access: Off") action Function(_renios_tools.toggle, "replay")
                text "Open the game's gallery or replay menu after enabling access."
                textbutton "Edit game values" action SetScreenVariable("section", "values")
            else:
                $ matches = _renios_tools.list_values(query)
                hbox:
                    spacing 8
                    textbutton "Back" action SetScreenVariable("section", "home")
                    textbutton "Search" action [SetScreenVariable("draft", query), SetScreenVariable("editing", "@search")]
                    textbutton "Previous" sensitive page > 0 action SetScreenVariable("page", page - 1)
                    textbutton "Next" sensitive (page + 1) * 6 < len(matches) action SetScreenVariable("page", page + 1)
                viewport:
                    draggable True
                    mousewheel True
                    vbox:
                        spacing 5
                        if not matches:
                            text "No matching values in the current game state."
                        for name in matches[page * 6:page * 6 + 6]:
                            $ value = _renios_tools.printable(_renios_tools.store_values()[name])
                            button:
                                action [SetScreenVariable("draft", value), SetScreenVariable("editing", name)]
                                text (name + "   " + value[:60]).replace("{", "{{") substitute False
