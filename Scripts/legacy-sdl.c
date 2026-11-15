/* SDL2 marks this function private, so the framework exports our wrapper. */
extern void SDL_iPhoneSetEventPump(int enabled);

void renios_legacy_set_event_pump(int enabled)
{
    SDL_iPhoneSetEventPump(enabled);
}

extern int SDL_IsTextInputActive(void);
extern void SDL_StartTextInput(void);
extern void SDL_StopTextInput(void);

int renios_legacy_toggle_keyboard(void)
{
    if (SDL_IsTextInputActive()) {
        SDL_StopTextInput();
        return 0;
    }
    SDL_StartTextInput();
    return 1;
}
