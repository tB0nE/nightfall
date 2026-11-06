$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Diagnostics;
using System.Threading;
public static class MouseButtonWatch {
    delegate IntPtr Hook(int code, IntPtr msg, IntPtr data);
    static Hook callback = OnMouse;
    static IntPtr handle;
    [StructLayout(LayoutKind.Sequential)] struct Point { public int x,y; }
    [StructLayout(LayoutKind.Sequential)] struct Mouse { public Point pt; public uint data,flags,time; public UIntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] struct Message { public IntPtr hwnd; public uint message; public UIntPtr wParam; public IntPtr lParam; public uint time; public Point point; public uint priv; }
    [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, Hook proc, IntPtr module, uint thread);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr msg, IntPtr data);
    [DllImport("user32.dll")] static extern bool PeekMessage(out Message message, IntPtr hwnd, uint min, uint max, uint remove);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref Message message);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref Message message);
    [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string name);
    static IntPtr OnMouse(int code, IntPtr msg, IntPtr ptr) {
        if (code >= 0) {
            long m = msg.ToInt64();
            if (m >= 0x201 && m <= 0x206) {
                Mouse data = (Mouse)Marshal.PtrToStructure(ptr,typeof(Mouse));
                Console.WriteLine("{0:HH:mm:ss.fff} event=0x{1:x} injected={2}",DateTime.Now,m,(data.flags & 1)!=0);
            }
        }
        return CallNextHookEx(handle,code,msg,ptr);
    }
    public static void Run() {
        handle=SetWindowsHookEx(14,callback,GetModuleHandle(null),0);
        if(handle==IntPtr.Zero) throw new Exception("Mouse hook unavailable");
        Console.WriteLine("Watching buttons for 25 seconds: 201/202=left down/up, 204/205=right down/up");
        try { var watch=Stopwatch.StartNew(); while(watch.ElapsedMilliseconds<25000) {
            Message m; while(PeekMessage(out m,IntPtr.Zero,0,0,1)) { TranslateMessage(ref m); DispatchMessage(ref m); }
            Thread.Sleep(1);
        }} finally { UnhookWindowsHookEx(handle); }
    }
}
'@
[MouseButtonWatch]::Run()
