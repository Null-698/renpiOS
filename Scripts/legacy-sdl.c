/* SDL2 marks this function private, so the framework exports our wrapper. */
extern void SDL_iPhoneSetEventPump(int enabled);

void renios_legacy_set_event_pump(int enabled)
{
    SDL_iPhoneSetEventPump(enabled);
}

extern void SDL_StopTextInput(void);

void renios_legacy_dismiss_keyboard(void)
{
    SDL_StopTextInput();
}
