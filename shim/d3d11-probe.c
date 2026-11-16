/*
 * Kelter graphics probe: opens a window, creates a Direct3D 11 device and swap chain,
 * prints the adapter name and clears the window to a fixed colour for a few seconds.
 * Used to check that DXMT really draws through Metal under the engine (see scripts/probe.sh).
 */
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
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
    window_class.lpszClassName = L"KelterProbe";
    RegisterClassW(&window_class);
    HWND window = CreateWindowW(L"KelterProbe", L"Kelter DX11 Test", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                                100, 100, 640, 360, NULL, NULL, instance, NULL);
    if (!window) { printf("probe: window failed\n"); return 2; }

    DXGI_SWAP_CHAIN_DESC desc = {0};
    desc.BufferCount = 2;
    desc.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.OutputWindow = window;
    desc.SampleDesc.Count = 1;
    desc.Windowed = TRUE;
    desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;

    IDXGISwapChain *swap_chain = NULL;
    ID3D11Device *device = NULL;
    ID3D11DeviceContext *context = NULL;
    D3D_FEATURE_LEVEL level = 0;
    HRESULT hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
                                               D3D11_SDK_VERSION, &desc, &swap_chain, &device, &level, &context);
    if (FAILED(hr)) { printf("probe: D3D11CreateDeviceAndSwapChain failed 0x%08lx\n", (unsigned long)hr); return 3; }

    IDXGIDevice *dxgi_device = NULL;
    IDXGIAdapter *adapter = NULL;
    DXGI_ADAPTER_DESC adapter_desc = {0};
    if (SUCCEEDED(ID3D11Device_QueryInterface(device, &IID_IDXGIDevice, (void **)&dxgi_device)) &&
        SUCCEEDED(IDXGIDevice_GetAdapter(dxgi_device, &adapter)) &&
        SUCCEEDED(IDXGIAdapter_GetDesc(adapter, &adapter_desc))) {
        printf("probe: adapter=%ls feature_level=0x%x\n", adapter_desc.Description, (unsigned)level);
    }

    ID3D11Texture2D *back_buffer = NULL;
    ID3D11RenderTargetView *target = NULL;
    IDXGISwapChain_GetBuffer(swap_chain, 0, &IID_ID3D11Texture2D, (void **)&back_buffer);
    ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)back_buffer, NULL, &target);

    /* Kelter red, easy to find in a screenshot. */
    const float colour[4] = { 0.55f, 0.10f, 0.20f, 1.0f };
    DWORD start = GetTickCount();
    unsigned frames = 0;
    MSG message;
    while (GetTickCount() - start < 6000) {
        while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE)) {
            if (message.message == WM_QUIT) goto done;
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        ID3D11DeviceContext_OMSetRenderTargets(context, 1, &target, NULL);
        ID3D11DeviceContext_ClearRenderTargetView(context, target, colour);
        IDXGISwapChain_Present(swap_chain, 1, 0);
        frames++;
    }
done:
    printf("probe: presented %u frames\n", frames);
    fflush(stdout);
    return 0;
}
