/*
 * KOReader launcher for Windows.
 *
 * The same executable runs in one of two modes:
 *
 * - launcher (default): the equivalent of `koreader.sh` on other platforms.
 *   It sets up the environment (data directory, logging), then runs the
 *   reader process, restarting it when requested (exit code 85), and
 *   reports abnormal terminations to the user.
 *
 * - reader (when `KO_WIN32_READER` is set by the launcher): runs `reader.lua`
 *   with an embedded LuaJIT.
 *
 * Note: the application manifest linked into this executable sets the
 * process code page to UTF-8, so all the narrow (`char *`) APIs used by
 * LuaJIT and our libraries transparently support Unicode.
 */

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

#include <windows.h>
#include <knownfolders.h>
#include <shellapi.h>
#include <shlobj.h>

#include "lauxlib.h"
#include "lua.h"
#include "lualib.h"

#define READER_ENV L"KO_WIN32_READER"
#define DATA_DIR_ENV L"KO_HOME"
#define PORTABLE_MARKER L"portable.txt"
#define RESTART_EXIT_CODE 85
#define LOG_NAME L"crash.log"
#define LOG_MAX_SIZE (1024 * 1024)

/* Helpers. {{{ */

static void fatal(const wchar_t *fmt, ...) {
    wchar_t msg[1024];
    va_list ap;
    va_start(ap, fmt);
    _vsnwprintf(msg, sizeof(msg) / sizeof(*msg) - 1, fmt, ap);
    va_end(ap);
    msg[sizeof(msg) / sizeof(*msg) - 1] = L'\0';
    MessageBoxW(NULL, msg, L"KOReader", MB_OK | MB_ICONERROR);
    ExitProcess(1);
}

static wchar_t *xwcsdup(const wchar_t *s) {
    wchar_t *d = _wcsdup(s);
    if (!d)
        fatal(L"Out of memory!");
    return d;
}

/* Concatenate NULL terminated list of strings. */
static wchar_t *wcsjoin(const wchar_t *first, ...) {
    size_t len = 0;
    va_list ap;
    va_start(ap, first);
    for (const wchar_t *s = first; s; s = va_arg(ap, const wchar_t *))
        len += wcslen(s);
    va_end(ap);
    wchar_t *res = malloc((len + 1) * sizeof(*res));
    if (!res)
        fatal(L"Out of memory!");
    res[0] = L'\0';
    va_start(ap, first);
    for (const wchar_t *s = first; s; s = va_arg(ap, const wchar_t *))
        wcscat(res, s);
    va_end(ap);
    return res;
}

static char *wide_to_utf8(const wchar_t *s) {
    int len = WideCharToMultiByte(CP_UTF8, 0, s, -1, NULL, 0, NULL, NULL);
    char *res = len > 0 ? malloc(len) : NULL;
    if (!res || !WideCharToMultiByte(CP_UTF8, 0, s, -1, res, len, NULL, NULL))
        fatal(L"Failed to convert string to UTF-8!");
    return res;
}

/* Directory containing this executable (without trailing separator). */
static wchar_t *get_install_dir(void) {
    DWORD size = MAX_PATH;
    for (;;) {
        wchar_t *path = malloc(size * sizeof(*path));
        if (!path)
            fatal(L"Out of memory!");
        DWORD len = GetModuleFileNameW(NULL, path, size);
        if (len == 0)
            fatal(L"Failed to retrieve the executable path (error %lu)!", GetLastError());
        if (len < size) {
            wchar_t *sep = wcsrchr(path, L'\\');
            if (sep)
                *sep = L'\0';
            return path;
        }
        free(path);
        size *= 2;
    }
}

static wchar_t *get_env(const wchar_t *name) {
    DWORD size = GetEnvironmentVariableW(name, NULL, 0);
    if (!size)
        return NULL;
    wchar_t *value = malloc(size * sizeof(*value));
    if (!value)
        fatal(L"Out of memory!");
    if (GetEnvironmentVariableW(name, value, size) != size - 1) {
        free(value);
        return NULL;
    }
    return value;
}

/* We use forward slashes as path separators on the Lua side. */
static void use_forward_slashes(wchar_t *path) {
    for (wchar_t *p = path; *p; ++p)
        if (*p == L'\\')
            *p = L'/';
}

static BOOL file_exists(const wchar_t *path) {
    DWORD attrs = GetFileAttributesW(path);
    return attrs != INVALID_FILE_ATTRIBUTES && !(attrs & FILE_ATTRIBUTE_DIRECTORY);
}

static wchar_t *get_full_path(const wchar_t *path) {
    DWORD size = GetFullPathNameW(path, 0, NULL, NULL);
    wchar_t *full = size ? malloc(size * sizeof(*full)) : NULL;
    if (!full || !GetFullPathNameW(path, size, full, NULL)) {
        free(full);
        return xwcsdup(path);
    }
    return full;
}

/* Append a command line argument, quoted as expected by `CommandLineToArgvW`. */
static void append_quoted_arg(wchar_t **cmdline, const wchar_t *arg) {
    size_t len = *cmdline ? wcslen(*cmdline) : 0;
    /* Worst case: every character escaped, plus quotes, separator and terminator. */
    wchar_t *res = realloc(*cmdline, (len + 2 * wcslen(arg) + 4) * sizeof(*res));
    if (!res)
        fatal(L"Out of memory!");
    wchar_t *p = res + len;
    if (len)
        *p++ = L' ';
    *p++ = L'"';
    for (const wchar_t *s = arg;; ++s) {
        size_t backslashes = 0;
        while (*s == L'\\') {
            ++backslashes;
            ++s;
        }
        if (!*s || *s == L'"') {
            /* Backslashes preceding a quote (or the closing one) must be doubled. */
            backslashes *= 2;
            if (*s == L'"')
                ++backslashes;
        }
        while (backslashes--)
            *p++ = L'\\';
        if (!*s)
            break;
        *p++ = *s;
    }
    *p++ = L'"';
    *p = L'\0';
    *cmdline = res;
}

/* }}} */

/* Reader mode. {{{ */

static int traceback(lua_State *L) {
    const char *msg = lua_tostring(L, 1);
    if (!msg)
        msg = "(error object is not a string)";
    luaL_traceback(L, L, msg, 1);
    return 1;
}

/* By default, the C runtime terminates the process when a function is called
 * with invalid parameters (e.g. `close(-1)`): let it fail with `EINVAL` instead,
 * like on POSIX systems. */
static void invalid_parameter_handler(const wchar_t *expression, const wchar_t *function,
                                      const wchar_t *file, unsigned int line, uintptr_t reserved) {
    (void)expression;
    (void)function;
    (void)file;
    (void)line;
    (void)reserved;
}

static int run_reader(const wchar_t *install_dir, int argc, wchar_t **argv) {
    /* Look for our libraries (and their dependencies) in `libs`. */
    wchar_t *libs_dir = wcsjoin(install_dir, L"\\libs", NULL);
    SetDllDirectoryW(libs_dir);
    free(libs_dir);

    /* No system error dialogs (e.g. when accessing an empty card reader). */
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOOPENFILEERRORBOX);

    _set_invalid_parameter_handler(invalid_parameter_handler);

    /* Open files in binary mode by default, like on POSIX systems
     * (e.g. `io.open(path, "r")` must not mangle line endings). */
    _set_fmode(_O_BINARY);

    lua_State *L = luaL_newstate();
    if (!L) {
        fputs("failed to create Lua state\n", stderr);
        return 1;
    }
    luaL_openlibs(L);

    /* Setup the `arg` table. */
    lua_createtable(L, argc - 1, 1);
    lua_pushliteral(L, "reader.lua");
    lua_rawseti(L, -2, 0);
    for (int i = 1; i < argc; ++i) {
        char *utf8 = wide_to_utf8(argv[i]);
        lua_pushstring(L, utf8);
        lua_rawseti(L, -2, i);
        free(utf8);
    }
    lua_setglobal(L, "arg");

    int ret = 0;
    lua_pushcfunction(L, traceback);
    if (luaL_loadfile(L, "reader.lua") || lua_pcall(L, 0, 0, -2)) {
        fprintf(stderr, "failed to run reader.lua: %s\n", lua_tostring(L, -1));
        ret = 1;
    }
    lua_close(L);
    return ret;
}

/* }}} */

/* Launcher mode. {{{ */

/* Where our settings & data are stored (c.f. `datastorage.lua`). */
static wchar_t *get_data_dir(const wchar_t *install_dir) {
    wchar_t *dir = get_env(DATA_DIR_ENV);
    if (dir && *dir)
        return dir;
    free(dir);
    /* Portable mode: everything is stored alongside the program. */
    wchar_t *marker = wcsjoin(install_dir, L"\\" PORTABLE_MARKER, NULL);
    BOOL portable = file_exists(marker);
    free(marker);
    if (portable)
        return xwcsdup(install_dir);
    /* Otherwise, use the (non-roaming) per-user application data directory:
     * our data includes caches, dictionaries, etc. */
    wchar_t *appdata = NULL;
    if (FAILED(SHGetKnownFolderPath(&FOLDERID_LocalAppData, KF_FLAG_CREATE, NULL, &appdata)))
        fatal(L"Failed to locate the local application data directory!");
    dir = wcsjoin(appdata, L"\\KOReader", NULL);
    CoTaskMemFree(appdata);
    return dir;
}

/* Open (append) the log file, rotating it when too big. */
static HANDLE open_log(const wchar_t *path) {
    WIN32_FILE_ATTRIBUTE_DATA attrs;
    if (GetFileAttributesExW(path, GetFileExInfoStandard, &attrs)
        && (attrs.nFileSizeHigh || attrs.nFileSizeLow > LOG_MAX_SIZE)) {
        wchar_t *old = wcsjoin(path, L".old", NULL);
        /* NOTE: may fail if another instance is running, that's fine. */
        MoveFileExW(path, old, MOVEFILE_REPLACE_EXISTING);
        free(old);
    }
    SECURITY_ATTRIBUTES sa = { sizeof(sa), NULL, TRUE };
    return CreateFileW(path, FILE_APPEND_DATA | SYNCHRONIZE,
                       FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                       &sa, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
}

static void log_printf(HANDLE log, const char *fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    int len = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (len > 0 && log != INVALID_HANDLE_VALUE) {
        DWORD written;
        WriteFile(log, buf, (DWORD)(len < (int)sizeof(buf) ? len : (int)sizeof(buf) - 1), &written, NULL);
    }
}

/* Return a handle suitable for inheritance (or `INVALID_HANDLE_VALUE`). */
static HANDLE inheritable_handle(HANDLE handle) {
    DWORD flags;
    if (!handle || handle == INVALID_HANDLE_VALUE || !GetHandleInformation(handle, &flags))
        return INVALID_HANDLE_VALUE;
    if (flags & HANDLE_FLAG_INHERIT)
        return handle;
    HANDLE dup;
    if (!DuplicateHandle(GetCurrentProcess(), handle, GetCurrentProcess(), &dup, 0, TRUE, DUPLICATE_SAME_ACCESS))
        return INVALID_HANDLE_VALUE;
    return dup;
}

static DWORD spawn_reader(const wchar_t *exe, const wchar_t *install_dir, const wchar_t *cmdline,
                          HANDLE job, HANDLE out, HANDLE err) {
    /* Only inherit the output handles. */
    HANDLE handles[2] = { out, err };
    DWORD nb_handles = out == err ? 1 : 2;
    SIZE_T size = 0;
    InitializeProcThreadAttributeList(NULL, 1, 0, &size);
    LPPROC_THREAD_ATTRIBUTE_LIST attrs = malloc(size);
    if (!attrs || !InitializeProcThreadAttributeList(attrs, 1, 0, &size)
        || !UpdateProcThreadAttribute(attrs, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                                      handles, nb_handles * sizeof(*handles), NULL, NULL))
        fatal(L"Failed to setup the reader process attributes (error %lu)!", GetLastError());

    STARTUPINFOEXW si = { 0 };
    si.StartupInfo.cb = sizeof(si);
    si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    si.StartupInfo.hStdInput = NULL;
    si.StartupInfo.hStdOutput = out;
    si.StartupInfo.hStdError = err;
    si.lpAttributeList = attrs;

    /* NOTE: `CreateProcessW` may modify the command line buffer. */
    wchar_t *cmd = xwcsdup(cmdline);
    PROCESS_INFORMATION pi;
    if (!CreateProcessW(exe, cmd, NULL, NULL, TRUE,
                        CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT,
                        NULL, install_dir, &si.StartupInfo, &pi))
        fatal(L"Failed to start KOReader (error %lu)!", GetLastError());
    free(cmd);
    DeleteProcThreadAttributeList(attrs);
    free(attrs);

    if (job)
        AssignProcessToJobObject(job, pi.hProcess);
    ResumeThread(pi.hThread);
    CloseHandle(pi.hThread);
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 1;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess);
    return code;
}

static int run_launcher(const wchar_t *install_dir, int argc, wchar_t **argv) {
    wchar_t *exe = wcsjoin(install_dir, L"\\koreader.exe", NULL);

    /* Setup the data directory. */
    wchar_t *data_dir = get_data_dir(install_dir);
    int ret = SHCreateDirectoryExW(NULL, data_dir, NULL);
    if (ret != ERROR_SUCCESS && ret != ERROR_ALREADY_EXISTS && ret != ERROR_FILE_EXISTS)
        fatal(L"Failed to create the data directory:\n\n%ls\n\n(error %d)", data_dir, ret);
    use_forward_slashes(data_dir);
    SetEnvironmentVariableW(DATA_DIR_ENV, data_dir);

    /* Logging: use the standard output when redirected, `crash.log` otherwise. */
    wchar_t *log_path = NULL;
    HANDLE out = inheritable_handle(GetStdHandle(STD_OUTPUT_HANDLE));
    HANDLE err = inheritable_handle(GetStdHandle(STD_ERROR_HANDLE));
    if (out == INVALID_HANDLE_VALUE) {
        log_path = wcsjoin(data_dir, L"/" LOG_NAME, NULL);
        out = err = open_log(log_path);
        if (out == INVALID_HANDLE_VALUE)
            fatal(L"Failed to open the log file:\n\n%ls\n\n(error %lu)", log_path, GetLastError());
    } else if (err == INVALID_HANDLE_VALUE) {
        err = out;
    }

    /* Ensure the reader process does not outlive us. */
    HANDLE job = CreateJobObjectW(NULL, NULL);
    if (job) {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION info = { 0 };
        /* NOTE: processes started by the reader (e.g. a web browser) must not be part of the job. */
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK;
        if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, &info, sizeof(info))) {
            CloseHandle(job);
            job = NULL;
        }
    }

    /* Build the initial command line: make (existing) paths absolute,
     * since the reader runs from the installation directory. */
    wchar_t *cmdline = NULL;
    append_quoted_arg(&cmdline, exe);
    wchar_t *restart_cmdline = xwcsdup(cmdline);
    for (int i = 1; i < argc; ++i) {
        if (argv[i][0] != L'-' && GetFileAttributesW(argv[i]) != INVALID_FILE_ATTRIBUTES) {
            wchar_t *full = get_full_path(argv[i]);
            use_forward_slashes(full);
            append_quoted_arg(&cmdline, full);
            free(full);
        } else {
            append_quoted_arg(&cmdline, argv[i]);
        }
    }

    SetEnvironmentVariableW(READER_ENV, L"1");
    DWORD code;
    for (;;) {
        code = spawn_reader(exe, install_dir, cmdline, job, out, err);
        if (code != RESTART_EXIT_CODE)
            break;
        /* Do not restart with the initial arguments. */
        free(cmdline);
        cmdline = xwcsdup(restart_cmdline);
    }

    if (code != 0) {
        log_printf(err, "\n[launcher] KOReader exited with code %lu (0x%08lx)\n", code, code);
        if (log_path) {
            wchar_t msg[256];
            _snwprintf(msg, sizeof(msg) / sizeof(*msg),
                       L"KOReader exited unexpectedly (code 0x%08lx).\n\nDo you want to open the log file?", code);
            if (MessageBoxW(NULL, msg, L"KOReader", MB_YESNO | MB_ICONERROR) == IDYES)
                ShellExecuteW(NULL, L"open", log_path, NULL, NULL, SW_SHOWNORMAL);
        }
    }

    return (int)code;
}

/* }}} */

int wmain(int argc, wchar_t **argv) {
    wchar_t *install_dir = get_install_dir();
    wchar_t *reader = get_env(READER_ENV);
    if (reader) {
        /* Don't leak our internal flag to processes started by the reader. */
        SetEnvironmentVariableW(READER_ENV, NULL);
        return run_reader(install_dir, argc, argv);
    }
    return run_launcher(install_dir, argc, argv);
}

/* vim: set foldmethod=marker foldlevel=0: */
