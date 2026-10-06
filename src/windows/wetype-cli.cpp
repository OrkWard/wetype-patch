// wetype-cli: per-app Chinese/English restore and CLI for WeType on Windows.
//
// WeType keeps Chinese/English in the TSF keyboard OPENCLOSE compartment
// (open = Chinese). It syncs one global value into each thread on focus.
// This tool never touches WeType: it reads/sets the open status of the focused
// window through IMM (WM_IME_CONTROL on the thread's default IME window).
#define WIN32_LEAN_AND_MEAN
#define UNICODE
#define _UNICODE
#include <windows.h>
#include <imm.h>
#include <sddl.h>
#include <cstdarg>
#include <cstdio>
#include <cwchar>
#include <map>
#include <string>
#include <vector>

#pragma comment(lib, "user32.lib")
#pragma comment(lib, "imm32.lib")
#pragma comment(lib, "advapi32.lib")

extern "C" BOOL WINAPI ImmSetHotKey(DWORD id, UINT modifiers, UINT vk, HKL hkl);
extern "C" BOOL WINAPI ImmGetHotKey(DWORD id, LPUINT modifiers, LPUINT vk, HKL *hkl);

namespace {

constexpr wchar_t kVersion[] = L"0.1.0";
constexpr WPARAM kImcGetOpenStatus = 5;
constexpr WPARAM kImcSetOpenStatus = 6;
constexpr UINT kMessageTimeoutMs = 300;
constexpr UINT kApplyDelayMs = 80;    // let WeType sync the global mode into the new thread first
constexpr UINT kVerifyDelayMs = 150;
constexpr UINT kPollMs = 1000;
constexpr UINT WM_APP_REQUEST = WM_APP + 1;
enum Timer : UINT_PTR { kTimerApply = 1, kTimerVerify = 2, kTimerPoll = 3 };
enum Exit { kOk = 0, kRefused = 1, kUsage = 2, kUnreachable = 3 };

// System IME hotkey IME_CHOTKEY_IME_NONIME_TOGGLE (Chinese Simplified, default Ctrl+Space).
// Deleting it makes Windows restore the default, so park it on an unused key instead.
constexpr DWORD kImeToggleHotKey = 0x10;
constexpr UINT kParkedModifiers = 0xC000 | MOD_CONTROL | MOD_ALT | MOD_SHIFT;  // left|right sides
constexpr UINT kParkedVk = VK_F24;

// ---------------------------------------------------------------- strings

std::wstring Lower(std::wstring s) {
    for (auto &c : s) c = (wchar_t)towlower(c);
    return s;
}

std::string Utf8(const std::wstring &s) {
    if (s.empty()) return {};
    int n = WideCharToMultiByte(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0, nullptr, nullptr);
    std::string out(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, s.data(), (int)s.size(), out.data(), n, nullptr, nullptr);
    return out;
}

std::wstring Wide(const std::string &s) {
    if (s.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
    std::wstring out(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), out.data(), n);
    return out;
}

std::vector<std::wstring> Split(const std::wstring &s, wchar_t sep) {
    std::vector<std::wstring> parts;
    size_t start = 0;
    for (;;) {
        size_t end = s.find(sep, start);
        parts.push_back(s.substr(start, end == std::wstring::npos ? std::wstring::npos : end - start));
        if (end == std::wstring::npos) return parts;
        start = end + 1;
    }
}

const wchar_t *ModeName(int mode) { return mode == 1 ? L"chinese" : mode == 0 ? L"english" : L"unknown"; }
int ParseMode(const std::wstring &s) { return s == L"chinese" ? 1 : s == L"english" ? 0 : -1; }

// App keys are lowercase exe names; "chrome" means "chrome.exe".
std::wstring NormalizeApp(std::wstring app) {
    app = Lower(app);
    if (!app.empty() && app.find(L'.') == std::wstring::npos) app += L".exe";
    return app;
}

class Json {
  public:
    Json &Str(const wchar_t *key, const std::wstring &value) {
        Key(key);
        Quote(value);
        return *this;
    }
    Json &Bool(const wchar_t *key, bool value) {
        Key(key);
        body_ += value ? L"true" : L"false";
        return *this;
    }
    Json &Map(const wchar_t *key, const std::map<std::wstring, std::wstring> &value) {
        Key(key);
        body_ += L'{';
        bool first = true;
        for (const auto &[k, v] : value) {
            if (!first) body_ += L',';
            first = false;
            Quote(k);
            body_ += L':';
            Quote(v);
        }
        body_ += L'}';
        return *this;
    }
    std::wstring Text() const { return L"{" + body_ + L"}"; }

  private:
    void Key(const wchar_t *key) {
        if (!body_.empty()) body_ += L',';
        Quote(key);
        body_ += L':';
    }
    void Quote(const std::wstring &s) {
        body_ += L'"';
        for (wchar_t c : s) {
            if (c == L'"' || c == L'\\') {
                body_ += L'\\';
                body_ += c;
            } else if (c < 0x20) {
                wchar_t buf[8];
                swprintf_s(buf, L"\\u%04x", c);
                body_ += buf;
            } else {
                body_ += c;
            }
        }
        body_ += L'"';
    }
    std::wstring body_;
};

// ---------------------------------------------------------------- paths & log

std::wstring StateDir() {
    wchar_t home[MAX_PATH] = {};
    GetEnvironmentVariableW(L"USERPROFILE", home, MAX_PATH);
    std::wstring dir = std::wstring(home) + L"\\.local\\state\\wetype-mode";
    // Create each missing component of .local\state\wetype-mode.
    for (size_t pos = wcslen(home) + 1; pos != std::wstring::npos; pos = dir.find(L'\\', pos + 1))
        CreateDirectoryW(dir.substr(0, pos).c_str(), nullptr);
    CreateDirectoryW(dir.c_str(), nullptr);
    return dir;
}

bool g_logToConsole = false;
bool g_logToFile = true;

void Log(const wchar_t *fmt, ...) {
    wchar_t msg[1024];
    va_list ap;
    va_start(ap, fmt);
    _vsnwprintf_s(msg, _TRUNCATE, fmt, ap);
    va_end(ap);
    SYSTEMTIME t;
    GetLocalTime(&t);
    wchar_t line[1200];
    swprintf_s(line, L"%04u-%02u-%02u %02u:%02u:%02u.%03u %s\r\n", t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute,
               t.wSecond, t.wMilliseconds, msg);
    std::string bytes = Utf8(line);
    HANDLE f = INVALID_HANDLE_VALUE;
    if (g_logToFile) {
        static std::wstring path = StateDir() + L"\\daemon.log";
        f = CreateFileW(path.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS,
                        FILE_ATTRIBUTE_NORMAL, nullptr);
    }
    if (f != INVALID_HANDLE_VALUE) {
        DWORD written;
        WriteFile(f, bytes.data(), (DWORD)bytes.size(), &written, nullptr);
        CloseHandle(f);
    }
    if (g_logToConsole) {
        fputws(line, stderr);
        fflush(stderr);
    }
}

void Print(const std::wstring &text) {
    std::wstring line = text + L"\n";
    HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
    DWORD mode, written;
    if (GetConsoleMode(out, &mode)) {
        WriteConsoleW(out, line.data(), (DWORD)line.size(), &written, nullptr);
    } else {
        std::string bytes = Utf8(line);
        WriteFile(out, bytes.data(), (DWORD)bytes.size(), &written, nullptr);
    }
}

// ---------------------------------------------------------------- target window

struct Target {
    HWND top = nullptr;
    HWND input = nullptr;  // focused window of the thread that owns input
    HWND ime = nullptr;    // that thread's default IME window
    DWORD tid = 0;
    DWORD pid = 0;
    std::wstring app;
    std::wstring cls;
};

std::wstring ExeName(DWORD pid) {
    HANDLE p = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!p) return {};
    wchar_t path[MAX_PATH] = {};
    DWORD n = MAX_PATH;
    BOOL ok = QueryFullProcessImageNameW(p, 0, path, &n);
    CloseHandle(p);
    if (!ok) return {};
    const wchar_t *base = wcsrchr(path, L'\\');
    return Lower(base ? base + 1 : path);
}

bool Resolve(HWND top, Target &t) {
    t = {};
    if (!top || !IsWindow(top)) return false;
    t.top = top;
    wchar_t cls[128] = {};
    GetClassNameW(top, cls, 128);
    t.cls = cls;
    t.tid = GetWindowThreadProcessId(top, &t.pid);
    t.app = ExeName(t.pid);
    if (t.app == L"applicationframehost.exe") {
        // UWP: the frame belongs to ApplicationFrameHost; input lives in a child
        // CoreWindow owned by the app process.
        struct Ctx { DWORD framePid; HWND found; } ctx{t.pid, nullptr};
        EnumChildWindows(top, [](HWND h, LPARAM l) -> BOOL {
            auto *c = reinterpret_cast<Ctx *>(l);
            DWORD pid = 0;
            GetWindowThreadProcessId(h, &pid);
            if (pid == c->framePid) return TRUE;
            c->found = h;
            return FALSE;
        }, reinterpret_cast<LPARAM>(&ctx));
        if (ctx.found) {
            t.input = ctx.found;
            t.tid = GetWindowThreadProcessId(ctx.found, &t.pid);
            t.app = ExeName(t.pid);
        }
    }
    if (!t.input) {
        GUITHREADINFO gti = {sizeof(gti)};
        t.input = GetGUIThreadInfo(t.tid, &gti) && gti.hwndFocus ? gti.hwndFocus : top;
    }
    t.ime = ImmGetDefaultIMEWnd(t.input);
    return !t.app.empty();
}

bool ResolveForeground(Target &t) { return Resolve(GetForegroundWindow(), t); }

// Shell surfaces that take foreground during task switching; not apps.
bool IsShellSurface(const Target &t) {
    static const wchar_t *kClasses[] = {L"Shell_TrayWnd", L"Shell_SecondaryTrayWnd", L"MultitaskingViewFrame",
                                        L"XamlExplorerHostIslandWindow", L"ForegroundStaging", L"TaskSwitcherWnd",
                                        L"TaskListThumbnailWnd", L"NotifyIconOverflowWindow", L"Progman", L"WorkerW"};
    for (auto *c : kClasses)
        if (t.cls == c) return true;
    return false;
}

// WeType is a zh-CN TSF profile; the thread's layout language is the cheap check.
bool ChineseImeActive(const Target &t) {
    return LOWORD(reinterpret_cast<UINT_PTR>(GetKeyboardLayout(t.tid))) == 0x0804;
}

int ReadMode(const Target &t) {
    DWORD_PTR open = 0;
    if (!t.ime || !SendMessageTimeoutW(t.ime, WM_IME_CONTROL, kImcGetOpenStatus, 0,
                                       SMTO_ABORTIFHUNG | SMTO_ERRORONEXIT, kMessageTimeoutMs, &open))
        return -1;
    return open ? 1 : 0;
}

bool WriteMode(const Target &t, int mode) {
    DWORD_PTR result = 0;
    return t.ime && SendMessageTimeoutW(t.ime, WM_IME_CONTROL, kImcSetOpenStatus, mode == 1 ? 1 : 0,
                                        SMTO_ABORTIFHUNG | SMTO_ERRORONEXIT, kMessageTimeoutMs, &result);
}

// Shared by daemon and direct CLI: status / chinese / english / toggle on the foreground app.
struct ModeResult {
    bool ok = false;
    int before = -1;
    int mode = -1;
    bool actionInvoked = false;
    std::wstring app;
    std::wstring error;
};

ModeResult ApplyOperation(const std::wstring &op) {
    ModeResult r;
    Target t;
    if (!ResolveForeground(t)) {
        r.error = L"No foreground window";
        return r;
    }
    r.app = t.app;
    if (!ChineseImeActive(t)) {
        r.error = L"Foreground thread is not using a Chinese (zh-CN) input method";
        return r;
    }
    r.before = r.mode = ReadMode(t);
    if (r.before < 0) {
        r.error = L"Cannot read IME open status (elevated window or no IME window)";
        return r;
    }
    if (op == L"status") {
        r.ok = true;
        return r;
    }
    int desired = op == L"toggle" ? !r.before : op == L"chinese" ? 1 : 0;
    if (desired == r.before) {
        r.ok = true;
        return r;
    }
    r.actionInvoked = true;
    if (!WriteMode(t, desired)) {
        r.error = L"Set request failed";
        return r;
    }
    r.mode = ReadMode(t);
    r.ok = r.mode == desired;
    if (!r.ok) r.error = L"Action returned but target state was not verified";
    return r;
}

// status.ok only means the request was answered; stateKnown/mode describe the IME.
bool ResultOk(const std::wstring &op, const ModeResult &r) { return op == L"status" || r.ok; }

void AddModeResult(Json &j, const std::wstring &op, const ModeResult &r) {
    j.Bool(L"ok", ResultOk(op, r)).Str(L"operation", op).Str(L"app", r.app).Str(L"mode", ModeName(r.mode))
        .Bool(L"stateKnown", r.mode >= 0);
    if (op != L"status" && r.before >= 0)
        j.Str(L"before", ModeName(r.before)).Bool(L"changed", r.before != r.mode).Bool(L"actionInvoked", r.actionInvoked);
    if (!r.error.empty()) j.Str(op == L"status" ? L"stateError" : L"error", r.error);
}

// ---------------------------------------------------------------- hotkey

std::wstring HotKeyStatus(bool fix, bool restore = false) {
    UINT mod = 0, vk = 0;
    HKL hkl = nullptr;
    BOOL present = ImmGetHotKey(kImeToggleHotKey, &mod, &vk, &hkl);
    bool ctrlSpace = present && vk == VK_SPACE && (mod & 0xF) == MOD_CONTROL;
    bool fixed = false;
    if (restore && !ctrlSpace) {
        fixed = ImmSetHotKey(kImeToggleHotKey, 0xC000 | MOD_CONTROL, VK_SPACE, nullptr) != FALSE;
        present = ImmGetHotKey(kImeToggleHotKey, &mod, &vk, &hkl);
        ctrlSpace = present && vk == VK_SPACE && (mod & 0xF) == MOD_CONTROL;
    }
    if (fix && (!present || vk != kParkedVk || mod != kParkedModifiers)) {
        fixed = ImmSetHotKey(kImeToggleHotKey, kParkedModifiers, kParkedVk, nullptr) != FALSE;
        if (fixed) Log(L"system IME toggle hotkey parked (was vk=%#x mod=%#x)", vk, mod);
        present = ImmGetHotKey(kImeToggleHotKey, &mod, &vk, &hkl);
        ctrlSpace = present && vk == VK_SPACE && (mod & 0xF) == MOD_CONTROL;
    }
    wchar_t buf[160];
    swprintf_s(buf, L"{\"ok\":true,\"hotkeyId\":\"0x10\",\"virtualKey\":\"%#x\",\"modifiers\":\"%#x\",\"ctrlSpace\":%s,\"changed\":%s}",
               present ? vk : 0, present ? mod : 0, ctrlSpace ? L"true" : L"false", fixed ? L"true" : L"false");
    return buf;
}

// ---------------------------------------------------------------- store

struct Store {
    bool autoOn = true;
    std::map<std::wstring, std::wstring> appModes;    // remembered
    std::map<std::wstring, std::wstring> fixedModes;  // configured; never overwritten by memory
    std::wstring path = StateDir() + L"\\modes.tsv";

    // Lines: "auto\t0|1", "app\tNAME\tMODE", "fixed\tNAME\tMODE".
    void Load() {
        HANDLE f = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
        if (f == INVALID_HANDLE_VALUE) return;
        std::string bytes;
        char buf[4096];
        DWORD n;
        while (ReadFile(f, buf, sizeof(buf), &n, nullptr) && n) bytes.append(buf, n);
        CloseHandle(f);
        for (auto &line : Split(Wide(bytes), L'\n')) {
            if (!line.empty() && line.back() == L'\r') line.pop_back();
            auto p = Split(line, L'\t');
            if (p.size() == 2 && p[0] == L"auto") autoOn = p[1] != L"0";
            if (p.size() == 3 && !p[1].empty() && ParseMode(p[2]) >= 0) {
                if (p[0] == L"app") appModes[Lower(p[1])] = p[2];
                if (p[0] == L"fixed") fixedModes[Lower(p[1])] = p[2];
            }
        }
    }

    void Save() const {
        std::wstring text = std::wstring(L"auto\t") + (autoOn ? L"1" : L"0") + L"\n";
        for (const auto &[k, v] : fixedModes) text += L"fixed\t" + k + L"\t" + v + L"\n";
        for (const auto &[k, v] : appModes) text += L"app\t" + k + L"\t" + v + L"\n";
        std::string bytes = Utf8(text);
        std::wstring tmp = path + L".tmp";
        HANDLE f = CreateFileW(tmp.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (f == INVALID_HANDLE_VALUE) {
            Log(L"save failed: %lu", GetLastError());
            return;
        }
        DWORD written;
        BOOL ok = WriteFile(f, bytes.data(), (DWORD)bytes.size(), &written, nullptr);
        CloseHandle(f);
        if (!ok || !MoveFileExW(tmp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
            Log(L"save failed: %lu", GetLastError());
    }
};

// ---------------------------------------------------------------- pipe

std::wstring TokenSid(HANDLE token) {
    BYTE buf[256];
    DWORD n;
    LPWSTR text = nullptr;
    std::wstring sid;
    if (GetTokenInformation(token, TokenUser, buf, sizeof(buf), &n) &&
        ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER *>(buf)->User.Sid, &text)) {
        sid = text;
        LocalFree(text);
    }
    return sid;
}

std::wstring CurrentSid() {
    HANDLE token;
    std::wstring sid = L"unknown";
    if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
        sid = TokenSid(token);
        CloseHandle(token);
    }
    return sid;
}

std::wstring PipeName(DWORD session, const std::wstring &sid) {
    return L"\\\\.\\pipe\\wetype-mode-" + std::to_wstring(session) + L"-" + sid;
}

std::wstring PipeName() {
    DWORD session = 0;
    ProcessIdToSessionId(GetCurrentProcessId(), &session);
    return PipeName(session, CurrentSid());
}

// Only the current user (and SYSTEM) may connect. The explicit medium label lets
// a non-elevated CLI talk to an elevated daemon of the same user.
bool PipeSecurity(SECURITY_ATTRIBUTES &sa) {
    std::wstring sddl = L"D:P(A;;GA;;;SY)(A;;GA;;;" + CurrentSid() + L")S:(ML;;NW;;;ME)";
    PSECURITY_DESCRIPTOR sd = nullptr;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.c_str(), SDDL_REVISION_1, &sd, nullptr)) return false;
    sa = {sizeof(sa), sd, FALSE};
    return true;
}

// Returns kOk with reply, kUnreachable if no daemon.
int CallDaemon(const std::wstring &request, std::wstring &reply, const std::wstring &pipe = PipeName()) {
    std::string req = Utf8(request);
    char buf[16384];
    DWORD read = 0;
    if (!CallNamedPipeW(pipe.c_str(), req.data(), (DWORD)req.size(), buf, sizeof(buf), &read, 3000))
        return kUnreachable;
    reply = Wide(std::string(buf, read));
    return kOk;
}

// ---------------------------------------------------------------- daemon

struct Request {
    std::wstring text;
    std::wstring reply;
    bool stop = false;
};

class Daemon {
  public:
    int Run() {
        HANDLE single = CreateMutexW(nullptr, TRUE, L"Local\\wetype-mode-daemon");
        if (!single || GetLastError() == ERROR_ALREADY_EXISTS) {
            Log(L"daemon already running");
            return kRefused;
        }
        store_.Load();
        HotKeyStatus(true);
        WNDCLASSW wc = {};
        wc.lpfnWndProc = &Daemon::WndProc;
        wc.hInstance = GetModuleHandleW(nullptr);
        wc.lpszClassName = L"wetype-mode-daemon";
        RegisterClassW(&wc);
        wnd_ = CreateWindowExW(0, wc.lpszClassName, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, wc.hInstance, nullptr);
        SetWindowLongPtrW(wnd_, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
        hook_ = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, nullptr, &Daemon::OnWinEvent, 0, 0,
                                WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
        if (!wnd_ || !hook_) {
            Log(L"daemon init failed: %lu", GetLastError());
            return kRefused;
        }
        instance_ = this;
        stopReplied_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        HANDLE pipe = CreateThread(nullptr, 0, &Daemon::PipeThread, this, 0, nullptr);
        SetTimer(wnd_, kTimerPoll, kPollMs, nullptr);
        Log(L"daemon %s ready (pid %lu, auto=%d)", kVersion, GetCurrentProcessId(), store_.autoOn);
        SendMessageW(wnd_, WM_TIMER, kTimerApply, 0);  // adopt the current foreground app
        MSG msg;
        while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        WaitForSingleObject(stopReplied_, 1000);
        UnhookWinEvent(hook_);
        if (pipe) CloseHandle(pipe);
        Log(L"daemon stopped (exit %d)", exitCode_);
        return exitCode_;  // kOk only after an explicit stop
    }

  private:
    static inline Daemon *instance_ = nullptr;

    static void CALLBACK OnWinEvent(HWINEVENTHOOK, DWORD, HWND hwnd, LONG idObject, LONG, DWORD, DWORD) {
        if (idObject != OBJID_WINDOW || !instance_) return;
        // Coalesce quick switches; also gives WeType time to sync the new thread.
        SetTimer(instance_->wnd_, kTimerApply, kApplyDelayMs, nullptr);
        (void)hwnd;
    }

    static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
        auto *self = reinterpret_cast<Daemon *>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
        if (self && msg == WM_TIMER) {
            if (wp == kTimerApply) {
                KillTimer(hwnd, kTimerApply);
                self->OnForeground();
            } else if (wp == kTimerVerify) {
                KillTimer(hwnd, kTimerVerify);
                self->Verify();
            } else if (wp == kTimerPoll) {
                self->Poll();
            }
            return 0;
        }
        if (self && msg == WM_APP_REQUEST) {
            self->Handle(*reinterpret_cast<Request *>(wp));
            return 0;
        }
        return DefWindowProcW(hwnd, msg, wp, lp);
    }

    int Desired(const std::wstring &app) const {
        auto f = store_.fixedModes.find(app);
        if (f != store_.fixedModes.end()) return ParseMode(f->second);
        auto m = store_.appModes.find(app);
        if (m != store_.appModes.end()) return ParseMode(m->second);
        return 0;  // default English
    }

    void Remember(const std::wstring &app, int mode) {
        if (!store_.autoOn || app.empty() || mode < 0) return;
        auto it = store_.appModes.find(app);
        if (it != store_.appModes.end() && it->second == ModeName(mode)) return;
        store_.appModes[app] = ModeName(mode);
        store_.Save();
    }

    // Foreground changed (after coalescing delay).
    void OnForeground() {
        if (stopped_) return;
        Target t;
        if (!ResolveForeground(t) || IsShellSurface(t)) return;
        if (t.app == front_.app && t.pid == front_.pid) {
            // Same process, maybe another window/thread: keep the user's current mode.
            // A new process of the same app is handled as a switch (save, then restore).
            front_ = t;
            return;
        }
        // The outgoing thread keeps its last open status after losing focus.
        int last = -1;
        if (!front_.app.empty() && frontChinese_) {
            last = ReadMode(front_);
            if (last < 0) last = lastObserved_;
            Remember(front_.app, last);
        }
        Log(L"switch %s(%s) -> %s%s", front_.app.c_str(), ModeName(last), t.app.c_str(),
            ChineseImeActive(t) ? L"" : L" [no zh-CN IME]");
        front_ = t;
        frontChinese_ = ChineseImeActive(t);
        lastObserved_ = -1;
        Restore();
    }

    void Restore() {
        if (!store_.autoOn || stopped_ || front_.app.empty() || !frontChinese_) return;
        int current = ReadMode(front_);
        if (current < 0) return;
        target_ = Desired(front_.app);
        if (current == target_) {
            Observe(current);
            return;
        }
        Log(L"apply %s: %s -> %s", front_.app.c_str(), ModeName(current), ModeName(target_));
        WriteMode(front_, target_);
        verifyRetries_ = 1;
        SetTimer(wnd_, kTimerVerify, kVerifyDelayMs, nullptr);
    }

    void Verify() {
        Target now;
        if (stopped_ || !ResolveForeground(now) || now.app != front_.app) return;
        int current = ReadMode(front_);
        if (current == target_) {
            Observe(current);
            return;
        }
        // Setting the open status is idempotent, so one retry is safe.
        if (verifyRetries_-- > 0 && current >= 0) {
            WriteMode(front_, target_);
            SetTimer(wnd_, kTimerVerify, kVerifyDelayMs, nullptr);
            return;
        }
        Log(L"mode result unknown for %s: want %s, read %s", front_.app.c_str(), ModeName(target_), ModeName(current));
    }

    void Poll() {
        if (++pollTicks_ % (60000 / kPollMs) == 0) HotKeyStatus(true);  // Windows may reload defaults
        if (stopped_ || front_.app.empty() || !frontChinese_) return;
        int current = ReadMode(front_);
        if (current >= 0) Observe(current);
    }

    void Observe(int mode) { lastObserved_ = mode; }

    void AddAutoStatus(Json &j) const {
        j.Bool(L"automaticModeManagement", store_.autoOn).Str(L"defaultMode", L"english").Str(L"frontmostApp", front_.app)
            .Map(L"appModes", store_.appModes).Map(L"fixedAppModes", store_.fixedModes);
    }

    void Handle(Request &req) {
        auto args = Split(req.text, L'\t');
        const std::wstring &op = args[0];
        Json j;
        if (op == L"status" || op == L"chinese" || op == L"english" || op == L"toggle") {
            ModeResult r = ApplyOperation(op);
            AddModeResult(j, op, r);
            if (op != L"status" && r.ok) {
                Remember(r.app, r.mode);  // explicit CLI choice is saved immediately
                if (r.app == front_.app) Observe(r.mode);
            }
            if (op == L"status") AddAutoStatus(j);
        } else if (op == L"auto-status" || op == L"apps" || op == L"auto-on" || op == L"auto-off") {
            if (op == L"auto-on" || op == L"auto-off") {
                store_.autoOn = op == L"auto-on";
                store_.Save();
                if (store_.autoOn) Restore();
            }
            j.Bool(L"ok", true).Str(L"operation", op);
            AddAutoStatus(j);
        } else if (op == L"app-set" || op == L"app-forget") {
            std::wstring app = args.size() > 1 ? NormalizeApp(args[1]) : L"";
            std::wstring mode = args.size() > 2 ? args[2] : L"";
            if (app.empty() || app.size() > 255) {
                j.Bool(L"ok", false).Str(L"operation", op).Str(L"error", L"Invalid app name");
            } else if (op == L"app-set" && ParseMode(mode) < 0) {
                j.Bool(L"ok", false).Str(L"operation", op).Str(L"error", L"Mode must be chinese or english");
            } else {
                if (op == L"app-set") store_.fixedModes[app] = mode;
                else store_.fixedModes.erase(app);
                store_.Save();
                if (app == front_.app) Restore();
                j.Bool(L"ok", true).Str(L"operation", op).Str(L"configuredApp", app);
                AddAutoStatus(j);
            }
        } else if (op == L"stop") {
            j.Bool(L"ok", true).Str(L"operation", op);
            stopped_ = true;
            exitCode_ = kOk;
            req.stop = true;
            PostQuitMessage(0);
        } else if (op == L"ping") {
            j.Bool(L"ok", true).Str(L"version", kVersion);
        } else {
            j.Bool(L"ok", false).Str(L"operation", op).Str(L"error", L"Unknown operation");
        }
        req.reply = j.Text();
    }

    static DWORD WINAPI PipeThread(void *param) {
        auto *self = static_cast<Daemon *>(param);
        SECURITY_ATTRIBUTES sa;
        if (!PipeSecurity(sa)) {
            Log(L"pipe security failed: %lu", GetLastError());
            return 1;
        }
        HANDLE pipe = CreateNamedPipeW(PipeName().c_str(), PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
                                       PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                                       1, 16384, 4096, 0, &sa);
        LocalFree(sa.lpSecurityDescriptor);
        if (pipe == INVALID_HANDLE_VALUE) {
            Log(L"pipe create failed: %lu", GetLastError());
            PostMessageW(self->wnd_, WM_QUIT, 0, 0);
            return 1;
        }
        for (;;) {
            if (!ConnectNamedPipe(pipe, nullptr) && GetLastError() != ERROR_PIPE_CONNECTED) continue;
            char buf[4096];
            DWORD read = 0;
            if (ReadFile(pipe, buf, sizeof(buf), &read, nullptr) && read) {
                Request req;
                req.text = Wide(std::string(buf, read));
                // All state lives on the main thread; this call is synchronous.
                SendMessageW(self->wnd_, WM_APP_REQUEST, reinterpret_cast<WPARAM>(&req), 0);
                std::string reply = Utf8(req.reply);
                DWORD written;
                WriteFile(pipe, reply.data(), (DWORD)reply.size(), &written, nullptr);
                FlushFileBuffers(pipe);
                if (req.stop) {
                    DisconnectNamedPipe(pipe);
                    SetEvent(self->stopReplied_);
                    return 0;
                }
            }
            DisconnectNamedPipe(pipe);
        }
    }

    Store store_;
    HWND wnd_ = nullptr;
    HWINEVENTHOOK hook_ = nullptr;
    HANDLE stopReplied_ = nullptr;
    Target front_;
    bool frontChinese_ = false;
    int lastObserved_ = -1;  // last mode read from the front app
    int target_ = -1;
    int verifyRetries_ = 0;
    unsigned pollTicks_ = 0;
    bool stopped_ = false;
    int exitCode_ = kRefused;
};

// ---------------------------------------------------------------- CLI

// The logon task (see install.nu) runs the daemon with highest privileges; running
// it on demand restarts the daemon elevated without a UAC prompt.
bool RunLogonTask() {
    wchar_t sys[MAX_PATH];
    GetSystemDirectoryW(sys, MAX_PATH);
    std::wstring exe = std::wstring(sys) + L"\\schtasks.exe";
    std::wstring cmd = L"\"" + exe + L"\" /run /tn wetype-mode";
    STARTUPINFOW si = {sizeof(si)};
    PROCESS_INFORMATION pi = {};
    if (!CreateProcessW(exe.c_str(), cmd.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi))
        return false;
    WaitForSingleObject(pi.hProcess, 5000);
    DWORD code = 1;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return code == 0;
}

bool WaitForDaemon() {
    std::wstring reply;
    for (int i = 0; i < 60; ++i) {
        Sleep(50);
        if (CallDaemon(L"ping", reply) == kOk) return true;
    }
    return false;
}

int StartDaemon() {
    std::wstring reply;
    if (CallDaemon(L"ping", reply) == kOk) {
        Print(L"{\"ok\":true,\"operation\":\"start\",\"alreadyRunning\":true}");
        return kOk;
    }
    if (RunLogonTask() && WaitForDaemon()) {
        Print(L"{\"ok\":true,\"operation\":\"start\",\"via\":\"task\"}");
        return kOk;
    }
    wchar_t self[MAX_PATH];
    GetModuleFileNameW(nullptr, self, MAX_PATH);
    std::wstring cmd = L"\"" + std::wstring(self) + L"\" daemon";
    STARTUPINFOW si = {sizeof(si)};
    PROCESS_INFORMATION pi = {};
    if (!CreateProcessW(self, cmd.data(), nullptr, nullptr, FALSE, DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP,
                        nullptr, nullptr, &si, &pi)) {
        Print(L"{\"ok\":false,\"operation\":\"start\",\"error\":\"CreateProcess failed\"}");
        return kRefused;
    }
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    if (WaitForDaemon()) {
        Print(L"{\"ok\":true,\"operation\":\"start\",\"via\":\"process\",\"elevated\":false,\"pid\":" +
              std::to_wstring(pi.dwProcessId) + L"}");
        return kOk;
    }
    Print(L"{\"ok\":false,\"operation\":\"start\",\"error\":\"Daemon did not answer; see daemon.log\"}");
    return kRefused;
}

int Usage() {
    fwprintf(stderr,
             L"wetype-cli %s\n"
             L"usage: wetype-cli <command>\n"
             L"  status | chinese | english | toggle      foreground app (works without daemon)\n"
             L"  auto-status | auto-on | auto-off | apps   per-app restore (daemon)\n"
             L"  app-set APP chinese|english | app-forget APP\n"
             L"  start | stop | daemon                      background daemon\n"
             L"  hotkey [fix|restore]                       system Ctrl+Space IME toggle\n",
             kVersion);
    return kUsage;
}

bool ReplyOk(const std::wstring &reply) { return reply.find(L"\"ok\":true") != std::wstring::npos; }

}  // namespace

int wmain(int argc, wchar_t **argv) {
    if (argc < 2) return Usage();
    std::wstring op = argv[1];
    std::vector<std::wstring> args(argv + 1, argv + argc);

    static const wchar_t *kNoArg[] = {L"status", L"chinese", L"english", L"toggle", L"auto-status",
                                      L"auto-on", L"auto-off", L"apps", L"stop", L"start", L"daemon"};
    bool known = false;
    for (auto *k : kNoArg) known |= op == k && args.size() == 1;
    known |= op == L"app-set" && args.size() == 3 && ParseMode(args[2]) >= 0;
    known |= op == L"app-forget" && args.size() == 2;
    known |= op == L"hotkey" && (args.size() == 1 || (args.size() == 2 && (args[1] == L"fix" || args[1] == L"restore")));
    if (!known) return Usage();

    if (op == L"daemon") {
        g_logToConsole = GetStdHandle(STD_ERROR_HANDLE) != nullptr;
        return Daemon().Run();
    }
    if (op == L"start") return StartDaemon();
    if (op == L"hotkey") {
        std::wstring reply = HotKeyStatus(args.size() == 2 && args[1] == L"fix", args.size() == 2 && args[1] == L"restore");
        Print(reply);
        return kOk;
    }

    std::wstring request = args[0];
    for (size_t i = 1; i < args.size(); ++i) request += L"\t" + args[i];
    std::wstring reply;
    if (CallDaemon(request, reply) == kOk) {
        Print(reply);
        return ReplyOk(reply) ? kOk : kRefused;
    }
    if (op == L"status" || op == L"chinese" || op == L"english" || op == L"toggle") {
        ModeResult r = ApplyOperation(op);
        Json j;
        AddModeResult(j, op, r);
        j.Bool(L"daemon", false);
        Print(j.Text());
        return ResultOk(op, r) ? kOk : kRefused;
    }
    Print(L"{\"ok\":false,\"operation\":\"" + op + L"\",\"error\":\"Daemon not running (wetype-cli start)\"}");
    return kUnreachable;
}
