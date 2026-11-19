init python:
    import renios_tools as _renios_tools

screen _renios_image_preview(asset):
    modal True
    zorder 19000
    add Solid("#080b10")
    add asset align (.5, .5) xysize (config.screen_width, config.screen_height) fit "contain"
    textbutton "Done" align (.98, .04) action Hide("_renios_image_preview") background Solid("#222837") padding (20, 10) text_color "#ffffff"
    key "game_menu" action Hide("_renios_image_preview")

screen _renios_link_button(targets):
    zorder 19001
    modal True
    for rect, signature in targets:
        button:
            xpos rect[0]
            ypos rect[1]
            xysize (rect[2], rect[3])
            background Solid("#55d8c439")
            action Function(_renios_tools.link_button, rect, signature)
    textbutton "Tap the mod button · Cancel" align (.5, .04) action Hide("_renios_link_button") background Solid("#17232eff") padding (16, 8) text_color "#ffffff"
    key "game_menu" action Hide("_renios_link_button")
