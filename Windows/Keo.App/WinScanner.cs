using System.Runtime.InteropServices;

namespace Keo;

/// Na Windows se bere scan kód klávesy, ne znak po českém rozložení.
public static class WinScanner
{
    private const int WhKeyboardLl = 13;
    private const int WmKeyDown = 0x0100;
    private const int WmSysKeyDown = 0x0104;
    private const int LlkhfExtended = 0x01;

    private static HookProc? proc;
    private static IntPtr hook;
    private static ScanBurstAssembler? assembler;
    private static Action<string>? onScan;
    private static Func<bool>? isScanning;
    private static Func<bool>? isEditing;
    private static bool shift;

    public static void Install(ScanBurstAssembler burst, Func<bool> scanning, Func<bool> editing, Action<string> scan)
    {
        if (!OperatingSystem.IsWindows() || hook != IntPtr.Zero) return;
        assembler = burst;
        isScanning = scanning;
        isEditing = editing;
        onScan = scan;
        proc = Hook;
        // Low-level hook musí mít hMod NULL; u single-file exe GetModuleHandle často selže.
        hook = SetWindowsHookEx(WhKeyboardLl, proc, IntPtr.Zero, 0);
    }

    public static void Remove()
    {
        if (hook != IntPtr.Zero) UnhookWindowsHookEx(hook);
        hook = IntPtr.Zero;
    }

    private static IntPtr Hook(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code < 0 || assembler == null) return CallNextHookEx(hook, code, wParam, lParam);
        var message = wParam.ToInt32();
        var info = Marshal.PtrToStructure<KbdLlHook>(lParam);
        var extended = (info.flags & LlkhfExtended) != 0;
        if (info.vkCode is 0x10 or 0xA0 or 0xA1)
        {
            shift = message is WmKeyDown or WmSysKeyDown;
            return CallNextHookEx(hook, code, wParam, lParam);
        }
        if (message is not (WmKeyDown or WmSysKeyDown)) return CallNextHookEx(hook, code, wParam, lParam);
        if (info.vkCode is 0x5B or 0x5C) return CallNextHookEx(hook, code, wParam, lParam);
        var scanning = isScanning?.Invoke() == true;
        var editing = isEditing?.Invoke() == true;
        if (!scanning)
        {
            var modifier = (GetAsyncKeyState(0x11) & 0x8000) != 0 || (GetAsyncKeyState(0x12) & 0x8000) != 0;
            if (editing || modifier || info.vkCode is 0x11 or 0x12 or 0xA2 or 0xA3 or 0xA4 or 0xA5)
                return CallNextHookEx(hook, code, wParam, lParam);
            return (IntPtr)1;
        }
        if (info.vkCode is 0x11 or 0x12 or 0xA2 or 0xA3 or 0xA4 or 0xA5) return (IntPtr)1;
        var time = info.time / 1000.0;
        if (UsKeys.IsTerminator(info.scanCode, extended))
        {
            Deliver(assembler.PushTerminator(time), time);
            return (IntPtr)1;
        }
        var character = UsKeys.FromScanCode(info.scanCode, shift || (GetAsyncKeyState(0x10) & 0x8000) != 0, extended);
        if (character == null) return (IntPtr)1;
        if (character == '\n')
        {
            Deliver(assembler.PushTerminator(time), time);
            return (IntPtr)1;
        }
        Deliver(assembler.PushForced(character.Value, time), time);
        return (IntPtr)1;
    }

    private static void Deliver(List<ScanBurstStep> steps, double time)
    {
        foreach (var step in steps)
            if (step.Kind == ScanBurstKind.CommitIdle && step.Text.Length > 0)
                onScan?.Invoke(step.Text);
        if (assembler?.NextWake(time) is { } wake)
        {
            var delay = Math.Max(0.01, wake - time);
            _ = Task.Delay(TimeSpan.FromSeconds(delay)).ContinueWith(_ =>
            {
                var tick = assembler.Tick(wake + 0.001);
                foreach (var step in tick)
                    if (step.Kind == ScanBurstKind.CommitIdle && step.Text.Length > 0)
                        onScan?.Invoke(step.Text);
            });
        }
    }

    private delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct KbdLlHook
    {
        public uint vkCode;
        public uint scanCode;
        public uint flags;
        public uint time;
        public IntPtr extra;
    }

    [DllImport("user32.dll")]
    private static extern IntPtr SetWindowsHookEx(int idHook, HookProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll")]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr GetModuleHandle(string? lpModuleName);

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int vKey);
}
