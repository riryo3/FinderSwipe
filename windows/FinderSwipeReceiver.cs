// FinderSwipeReceiver (試作)
// Mac 側の FinderSwipe から届く「合図」(UDP ブロードキャスト)を受けて、
// エクスプローラーのショートカットに変換して送る Windows 用の受け専用プログラム。
//   戻る = Alt+← / 進む = Alt+→ / 上の階層 = Alt+↑ / 開く = Enter
// エクスプローラーが最前面のときだけ実行する。合図の形式は Mac 版と共通。

using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;

internal static class Program
{
    private const int Port = 45987;
    private const string Magic = "FSWIPE1 ";
    private static readonly Dictionary<long, DateTime> Seen = new Dictionary<long, DateTime>();

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr hWnd, StringBuilder text, int count);

    [DllImport("user32.dll")]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public uint type;
        public INPUTUNION u;
    }

    [StructLayout(LayoutKind.Explicit, Size = 32)]
    private struct INPUTUNION
    {
        [FieldOffset(0)] public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    private const uint INPUT_KEYBOARD = 1;
    private const uint KEYEVENTF_KEYUP = 0x0002;
    private const ushort VK_MENU = 0x12;   // Alt
    private const ushort VK_LEFT = 0x25;
    private const ushort VK_UP = 0x26;
    private const ushort VK_RIGHT = 0x27;
    private const ushort VK_RETURN = 0x0D;

    private static INPUT MakeKey(ushort vk, bool keyUp)
    {
        INPUT i = new INPUT();
        i.type = INPUT_KEYBOARD;
        i.u.ki.wVk = vk;
        i.u.ki.wScan = 0;
        i.u.ki.dwFlags = keyUp ? KEYEVENTF_KEYUP : 0;
        i.u.ki.time = 0;
        i.u.ki.dwExtraInfo = IntPtr.Zero;
        return i;
    }

    private static void SendKeys(params INPUT[] inputs)
    {
        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT)));
    }

    private static void AltCombo(ushort vk)
    {
        SendKeys(MakeKey(VK_MENU, false), MakeKey(vk, false), MakeKey(vk, true), MakeKey(VK_MENU, true));
    }

    private static void Press(ushort vk)
    {
        SendKeys(MakeKey(vk, false), MakeKey(vk, true));
    }

    private static bool ExplorerIsForeground()
    {
        StringBuilder sb = new StringBuilder(256);
        GetClassName(GetForegroundWindow(), sb, sb.Capacity);
        string cls = sb.ToString();
        return cls == "CabinetWClass" || cls == "ExploreWClass";
    }

    private static void Act(string action)
    {
        switch (action)
        {
            case "back": AltCombo(VK_LEFT); break;
            case "forward": AltCombo(VK_RIGHT); break;
            case "parent": AltCombo(VK_UP); break;
            case "open": Press(VK_RETURN); break;
            default: return;
        }
        Console.WriteLine("実行: " + action);
    }

    private static void Main()
    {
        Console.WriteLine("FinderSwipeReceiver: UDP " + Port + " で合図を待っています (Ctrl+C で終了)");
        UdpClient udp = new UdpClient(Port);
        IPEndPoint from = new IPEndPoint(IPAddress.Any, 0);
        while (true)
        {
            byte[] data = udp.Receive(ref from);
            string s = Encoding.UTF8.GetString(data);
            if (!s.StartsWith(Magic)) continue;
            string[] parts = s.Substring(Magic.Length).Split(' ');
            if (parts.Length != 2) continue;
            long seq;
            if (!long.TryParse(parts[0], out seq)) continue;

            // 同じ合図は3回送られてくるので、2秒以内の重複は捨てる
            DateTime now = DateTime.UtcNow;
            DateTime seenAt;
            if (Seen.TryGetValue(seq, out seenAt) && (now - seenAt).TotalSeconds < 2) continue;
            Seen[seq] = now;

            if (!ExplorerIsForeground())
            {
                Console.WriteLine("受信: " + parts[1] + " (エクスプローラーが最前面ではないので実行しません)");
                continue;
            }
            Console.WriteLine("受信: " + parts[1]);
            Act(parts[1]);
        }
    }
}
