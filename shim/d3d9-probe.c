/*
 * Kelter DirectX 9 probe: like d3d11-probe.c, but through Direct3D 9, so the DX9 path can be
 * checked (WineD3D over OpenGL versus DXVK over Vulkan). Prints the adapter and frame count.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d9.h>
#include <stdio.h>

static LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM w, LPARAM l)
{
    if (message == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcW(window, message, w, l);
}

int main(void)
{
    HINSTANCE instance = GetModuleHandleW(NULL);
    WNDCLASSW window_class = {0};
    window_class.lpfnWndProc = window_proc;
    window_class.hInstance = instance;
    window_class.lpszClassName = L"KelterProbe9";
    RegisterClassW(&window_class);
    HWND window = CreateWindowW(L"KelterProbe9", L"Kelter DX9 Test", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                                100, 100, 640, 360, NULL, NULL, instance, NULL);
    if (!window) { printf("probe9: window failed\n"); return 2; }

    IDirect3D9 *d3d = Direct3DCreate9(D3D_SDK_VERSION);
    if (!d3d) { printf("probe9: Direct3DCreate9 failed\n"); return 3; }
    D3DADAPTER_IDENTIFIER9 id;
    if (SUCCEEDED(IDirect3D9_GetAdapterIdentifier(d3d, D3DADAPTER_DEFAULT, 0, &id))) {
        printf("probe9: adapter=%s driver=%s\n", id.Description, id.Driver);
    }

    D3DPRESENT_PARAMETERS params = {0};
    params.Windowed = TRUE;
    params.SwapEffect = D3DSWAPEFFECT_DISCARD;
    params.BackBufferFormat = D3DFMT_UNKNOWN;
    params.hDeviceWindow = window;
    params.PresentationInterval = D3DPRESENT_INTERVAL_ONE;

    IDirect3DDevice9 *device = NULL;
    HRESULT hr = IDirect3D9_CreateDevice(d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, window,
                                         D3DCREATE_HARDWARE_VERTEXPROCESSING, &params, &device);
    if (FAILED(hr)) { printf("probe9: CreateDevice failed 0x%08lx\n", (unsigned long)hr); return 4; }

    DWORD start = GetTickCount();
    unsigned frames = 0;
    MSG message;
    while (GetTickCount() - start < 6000) {
        while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE)) {
            if (message.message == WM_QUIT) goto done;
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        IDirect3DDevice9_Clear(device, 0, NULL, D3DCLEAR_TARGET, D3DCOLOR_XRGB(140, 26, 51), 1.0f, 0);
        IDirect3DDevice9_BeginScene(device);
        IDirect3DDevice9_EndScene(device);
        IDirect3DDevice9_Present(device, NULL, NULL, NULL, NULL);
        frames++;
    }
done:
    printf("probe9: presented %u frames\n", frames);
    fflush(stdout);
    return 0;
}
