/*
 * Kelter test helper: brings a window (by title) to the front inside the bottle and sends key
 * presses, so a game's title screen can be passed without touching the Mac's own input.
 * Usage: sendkey.exe "<window title>" <virtual key code, decimal> [count] [delay ms]
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv)
{
    if (argc < 3) { printf("sendkey: Aufruf: sendkey <Titel> <VK> [Anzahl] [Pause ms]\n"); return 2; }
    HWND window = FindWindowA(NULL, argv[1]);
    if (!window) { printf("sendkey: Fenster '%s' nicht gefunden\n", argv[1]); return 3; }
    WORD key = (WORD)atoi(argv[2]);
    int count = argc > 3 ? atoi(argv[3]) : 1;
    int pause = argc > 4 ? atoi(argv[4]) : 400;
    SetForegroundWindow(window);
    SetFocus(window);
    Sleep(300);
    for (int i = 0; i < count; i++) {
        INPUT input[2];
        ZeroMemory(input, sizeof(input));
        input[0].type = INPUT_KEYBOARD;
        input[0].ki.wVk = key;
        input[0].ki.wScan = (WORD)MapVirtualKeyA(key, MAPVK_VK_TO_VSC);
        input[1] = input[0];
        input[1].ki.dwFlags = KEYEVENTF_KEYUP;
        SendInput(1, &input[0], sizeof(INPUT));
        Sleep(80);
        SendInput(1, &input[1], sizeof(INPUT));
        Sleep(pause);
    }
    printf("sendkey: %d x VK %u an '%s'\n", count, key, argv[1]);
    return 0;
}
