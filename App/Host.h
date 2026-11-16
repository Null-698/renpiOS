#pragma once

int renios_play(const char *project, const char *saves, const char *engine, const char *orientation, int playbackProbe);
void renios_request_quit(void);
void renios_toggle_keyboard(void);
void renios_playback_key(int scancode, int keycode);
