/*
 * Kelter Vulkan probe: asks the Vulkan driver (through Wine's vulkan-1.dll) which shader stages
 * support subgroup operations. DOOM Eternal refuses to start without its required stages.
 * Needs no Vulkan headers: the few structures used are declared here.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdint.h>

typedef void *VkInstance;
typedef void *VkPhysicalDevice;
typedef void (*PFN_void)(void);
typedef PFN_void (__stdcall *PFN_GetInstanceProcAddr)(VkInstance, const char *);

typedef struct { int sType; const void *pNext; const char *app; uint32_t appVersion; const char *engine; uint32_t engineVersion; uint32_t apiVersion; } AppInfo;
typedef struct { int sType; const void *pNext; uint32_t flags; const AppInfo *app; uint32_t layerCount; const char *const *layers; uint32_t extCount; const char *const *exts; } InstanceInfo;
typedef struct { int sType; void *pNext; uint32_t subgroupSize; uint32_t supportedStages; uint32_t supportedOperations; uint32_t quadOperationsInAllStages; } SubgroupProps;
typedef struct { int sType; void *pNext; uint32_t apiVersion; uint32_t driverVersion; uint32_t vendorID; uint32_t deviceID; uint32_t deviceType; char deviceName[256]; uint8_t rest[2048]; } Props2;

typedef int (__stdcall *PFN_CreateInstance)(const InstanceInfo *, const void *, VkInstance *);
typedef int (__stdcall *PFN_EnumDevices)(VkInstance, uint32_t *, VkPhysicalDevice *);
typedef void (__stdcall *PFN_GetProps2)(VkPhysicalDevice, Props2 *);

static void stages(uint32_t s)
{
    const char *names[] = { "vertex", "tess_control", "tess_eval", "geometry", "fragment", "compute" };
    for (int i = 0; i < 6; i++) if (s & (1u << i)) printf(" %s", names[i]);
    if (s & ~0x3fu) printf(" (+0x%x)", s & ~0x3fu);
}

static void operations(uint32_t o)
{
    const char *names[] = { "basic", "vote", "arithmetic", "ballot", "shuffle", "shuffle_relative", "clustered", "quad" };
    for (int i = 0; i < 8; i++) if (o & (1u << i)) printf(" %s", names[i]);
}

int main(void)
{
    HMODULE vulkan = LoadLibraryA("vulkan-1.dll");
    if (!vulkan) { printf("vk: vulkan-1.dll fehlt\n"); return 2; }
    PFN_GetInstanceProcAddr gipa = (PFN_GetInstanceProcAddr)GetProcAddress(vulkan, "vkGetInstanceProcAddr");
    PFN_CreateInstance create = (PFN_CreateInstance)gipa(NULL, "vkCreateInstance");

    AppInfo app = { 0, NULL, "KelterProbe", 1, "Kelter", 1, (1u << 22) | (1u << 12) }; /* Vulkan 1.1 */
    InstanceInfo info = { 1, NULL, 0, &app, 0, NULL, 0, NULL };
    VkInstance instance = NULL;
    int result = create(&info, NULL, &instance);
    if (result) { printf("vk: vkCreateInstance %d\n", result); return 3; }

    PFN_EnumDevices enumerate = (PFN_EnumDevices)gipa(instance, "vkEnumeratePhysicalDevices");
    PFN_GetProps2 props2 = (PFN_GetProps2)gipa(instance, "vkGetPhysicalDeviceProperties2");
    uint32_t count = 8;
    VkPhysicalDevice devices[8];
    enumerate(instance, &count, devices);
    for (uint32_t i = 0; i < count; i++) {
        SubgroupProps subgroup = { 1000094000, NULL, 0, 0, 0, 0 };
        Props2 props = { 1000059001, &subgroup };
        props2(devices[i], &props);
        printf("vk: device=%s api=%u.%u.%u subgroupSize=%u stages:", props.deviceName,
               props.apiVersion >> 22, (props.apiVersion >> 12) & 0x3ff, props.apiVersion & 0xfff, subgroup.subgroupSize);
        stages(subgroup.supportedStages);
        printf(" | ops:");
        operations(subgroup.supportedOperations);
        printf(" | quadAllStages=%u\n", subgroup.quadOperationsInAllStages);
    }
    fflush(stdout);
    return 0;
}
