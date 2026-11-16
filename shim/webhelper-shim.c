/*
 * Kelter web helper shim.
 *
 * Steam's embedded Chromium (CEF 126 and later) paints its windows black under Wine on macOS
 * unless it runs without GPU and in a single process. Steam does not forward those switches,
 * so Kelter puts this program in place of steamwebhelper.exe. It starts the real helper,
 * renamed to steamwebhelper.kelter-real.exe, with the extra switches and mirrors its exit code.
 *
 * Built with: zig cc -target x86_64-windows-gnu (see scripts/build-shim.sh).
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wchar.h>

static const wchar_t kRealName[] = L"steamwebhelper.kelter-real.exe";
static const wchar_t kExtraSwitches[] = L" --disable-gpu --disable-gpu-compositing --single-process";

/* Skips argv[0] the way the Windows command line parser does, then any blanks after it. */
static const wchar_t *skip_program_name(const wchar_t *cmd)
{
    if (*cmd == L'"') {
        cmd++;
        while (*cmd && *cmd != L'"') cmd++;
        if (*cmd == L'"') cmd++;
    } else {
        while (*cmd && *cmd != L' ' && *cmd != L'\t') cmd++;
    }
    while (*cmd == L' ' || *cmd == L'\t') cmd++;
    return cmd;
}

int WINAPI WinMain(HINSTANCE instance, HINSTANCE previous, LPSTR ansi_command_line, int show)
{
    (void)instance; (void)previous; (void)ansi_command_line; (void)show;

    wchar_t real[MAX_PATH * 2];
    DWORD length = GetModuleFileNameW(NULL, real, MAX_PATH * 2);
    if (length == 0 || length >= MAX_PATH * 2) return 1;
    wchar_t *slash = wcsrchr(real, L'\\');
    if (!slash) return 1;
    slash[1] = 0;
    if (wcslen(real) + wcslen(kRealName) + 1 > MAX_PATH * 2) return 1;
    wcscat(real, kRealName);

    const wchar_t *arguments = skip_program_name(GetCommandLineW());
    /* Child processes (renderer, utility, crashpad) keep their own switches untouched. */
    const BOOL top_level = wcsstr(arguments, L"--type=") == NULL;

    size_t capacity = wcslen(real) + wcslen(arguments) + wcslen(kExtraSwitches) + 8;
    wchar_t *command_line = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, capacity * sizeof(wchar_t));
    if (!command_line) return 1;
    wcscat(command_line, L"\"");
    wcscat(command_line, real);
    wcscat(command_line, L"\" ");
    wcscat(command_line, arguments);
    if (top_level) wcscat(command_line, kExtraSwitches);

    /* If Steam kills this shim, the job takes the real helper down with it. */
    HANDLE job = CreateJobObjectW(NULL, NULL);
    if (job) {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits;
        ZeroMemory(&limits, sizeof(limits));
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits));
    }

    STARTUPINFOW startup;
    PROCESS_INFORMATION process;
    ZeroMemory(&startup, sizeof(startup));
    startup.cb = sizeof(startup);
    if (!CreateProcessW(real, command_line, NULL, NULL, TRUE, CREATE_SUSPENDED, NULL, NULL, &startup, &process)) {
        return 1;
    }
    if (job) AssignProcessToJobObject(job, process.hProcess);
    ResumeThread(process.hThread);
    CloseHandle(process.hThread);

    WaitForSingleObject(process.hProcess, INFINITE);
    DWORD exit_code = 1;
    GetExitCodeProcess(process.hProcess, &exit_code);
    CloseHandle(process.hProcess);
    return (int)exit_code;
}
