// GmmkHid.cs — HID driver for the Glorious GMMK v1 (2021 revision, USB 320F:5064).
//
// Protocol derived from USB captures of the official Glorious editor (OpenRGB
// issue #2935) and prior reverse engineering of the 0C45:652F revision
// (dokutan/rgb_keyboard, francisrstokes/GMMK-Driver). All packets are 64-byte
// HID output reports, report ID 0x04:
//
//   [0]    0x04                   report ID
//   [1..2] checksum               little-endian sum of bytes [3..63]
//   [3..]  command
//
// Commands seen on the wire:
//   01                      begin transaction
//   02                      end transaction
//   03 2C                   read current state (reply arrives as input report 04)
//   06 01 00 00 00 <mode>   set onboard effect mode (1..18)
//   06 01 01 00 00 <level>  brightness 0..4 (0 = LEDs off)
//   06 01 02 00 00 <speed>  effect speed 0..3
//   06 01 04 00 00 <dir>    effect direction
//   06 03 05 00 00 <R G B>  effect/static color
//
// Compiled in-memory by PowerShell's Add-Type; no build step.

using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace AuraGmmkBridge
{
    public static class Gmmk
    {
        // Overridable for other GMMK revisions (e.g. the older "vid_0c45&pid_652f"),
        // normally set from config.json's "vidPid" by the calling script.
        public static string VidPid = "vid_320f&pid_5064";
        const int ReportLen = 64;

        static SafeFileHandle _dev;
        public static string Status = "not connected";

        // --- Win32 ------------------------------------------------------------

        [DllImport("hid.dll")] static extern void HidD_GetHidGuid(out Guid gid);
        [DllImport("hid.dll")] static extern bool HidD_SetOutputReport(SafeFileHandle h, byte[] buf, int len);
        [DllImport("hid.dll")] static extern bool HidD_FlushQueue(SafeFileHandle h);
        [DllImport("hid.dll")] static extern bool HidD_GetPreparsedData(SafeFileHandle h, out IntPtr data);
        [DllImport("hid.dll")] static extern bool HidD_FreePreparsedData(IntPtr data);
        [DllImport("hid.dll")] static extern int HidP_GetCaps(IntPtr data, out HidCaps caps);

        [StructLayout(LayoutKind.Sequential)]
        struct HidCaps
        {
            public ushort Usage, UsagePage;
            public ushort InputReportByteLength, OutputReportByteLength, FeatureReportByteLength;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)] public ushort[] Reserved;
            public ushort NumberLinkCollectionNodes;
            public ushort NumberInputButtonCaps, NumberInputValueCaps, NumberInputDataIndices;
            public ushort NumberOutputButtonCaps, NumberOutputValueCaps, NumberOutputDataIndices;
            public ushort NumberFeatureButtonCaps, NumberFeatureValueCaps, NumberFeatureDataIndices;
        }

        [DllImport("setupapi.dll", CharSet = CharSet.Auto)]
        static extern IntPtr SetupDiGetClassDevs(ref Guid gid, IntPtr enumerator, IntPtr hwnd, int flags);
        [DllImport("setupapi.dll")]
        static extern bool SetupDiEnumDeviceInterfaces(IntPtr devs, IntPtr devInfo, ref Guid gid, int index, ref DevIfaceData ifaceData);
        [DllImport("setupapi.dll", CharSet = CharSet.Auto)]
        static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr devs, ref DevIfaceData ifaceData, IntPtr detail, int detailSize, out int required, IntPtr devInfo);
        [DllImport("setupapi.dll")]
        static extern bool SetupDiDestroyDeviceInfoList(IntPtr devs);

        [StructLayout(LayoutKind.Sequential)]
        struct DevIfaceData { public int Size; public Guid Gid; public int Flags; public IntPtr Reserved; }

        [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool ReadFile(SafeFileHandle h, byte[] buf, int count, IntPtr read, ref NativeOverlapped ov);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetOverlappedResult(SafeFileHandle h, ref NativeOverlapped ov, out int transferred, bool wait);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool CancelIo(SafeFileHandle h);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr CreateEvent(IntPtr sec, bool manualReset, bool initialState, IntPtr name);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern uint WaitForSingleObject(IntPtr h, uint ms);
        [DllImport("kernel32.dll")]
        static extern bool CloseHandle(IntPtr h);

        // --- device discovery -------------------------------------------------

        static string FindDevicePath()
        {
            Guid gid; HidD_GetHidGuid(out gid);
            IntPtr devs = SetupDiGetClassDevs(ref gid, IntPtr.Zero, IntPtr.Zero, 0x12 /* PRESENT | DEVICEINTERFACE */);
            if (devs == (IntPtr)(-1)) throw new IOException("SetupDiGetClassDevs failed");
            try
            {
                var ifaceData = new DevIfaceData();
                ifaceData.Size = Marshal.SizeOf(ifaceData);
                for (int i = 0; SetupDiEnumDeviceInterfaces(devs, IntPtr.Zero, ref gid, i, ref ifaceData); i++)
                {
                    int required;
                    SetupDiGetDeviceInterfaceDetail(devs, ref ifaceData, IntPtr.Zero, 0, out required, IntPtr.Zero);
                    IntPtr detail = Marshal.AllocHGlobal(required);
                    try
                    {
                        Marshal.WriteInt32(detail, IntPtr.Size == 8 ? 8 : 6);   // cbSize
                        if (!SetupDiGetDeviceInterfaceDetail(devs, ref ifaceData, detail, required, out required, IntPtr.Zero))
                            continue;
                        string path = Marshal.PtrToStringAuto(detail + 4);
                        if (path.IndexOf(VidPid, StringComparison.OrdinalIgnoreCase) < 0) continue;

                        // The keyboard exposes several HID collections; the vendor
                        // one is identified by its 64-byte report length, not COL#.
                        var h = CreateFile(path, 0xC0000000 /* GENERIC_RW */, 3, IntPtr.Zero, 3 /* OPEN_EXISTING */, 0, IntPtr.Zero);
                        if (h.IsInvalid) continue;
                        IntPtr pp;
                        if (HidD_GetPreparsedData(h, out pp))
                        {
                            HidCaps caps;
                            HidP_GetCaps(pp, out caps);
                            HidD_FreePreparsedData(pp);
                            if (caps.OutputReportByteLength >= ReportLen)
                            {
                                h.Dispose();
                                return path;
                            }
                        }
                        h.Dispose();
                    }
                    finally { Marshal.FreeHGlobal(detail); }
                }
            }
            finally { SetupDiDestroyDeviceInfoList(devs); }
            return null;
        }

        public static void Connect()
        {
            if (_dev != null && !_dev.IsInvalid && !_dev.IsClosed) { _dev.Dispose(); _dev = null; }
            string path = FindDevicePath();
            if (path == null) throw new IOException("GMMK (320F:5064) vendor HID collection not found — is the keyboard plugged in?");
            _dev = CreateFile(path, 0xC0000000, 3, IntPtr.Zero, 3, 0x40000000 /* FILE_FLAG_OVERLAPPED */, IntPtr.Zero);
            if (_dev.IsInvalid) throw new IOException("CreateFile failed for " + path + " (error " + Marshal.GetLastWin32Error() + ")");
            Status = "connected: " + path;
        }

        // --- protocol ---------------------------------------------------------

        static byte[] Packet(params byte[] cmd)
        {
            var b = new byte[ReportLen];
            b[0] = 0x04;
            Array.Copy(cmd, 0, b, 3, cmd.Length);
            int sum = 0;
            for (int i = 3; i < ReportLen; i++) sum += b[i];
            b[1] = (byte)(sum & 0xFF);
            b[2] = (byte)((sum >> 8) & 0xFF);
            return b;
        }

        static void Send(byte[] report)
        {
            if (_dev == null || _dev.IsInvalid || _dev.IsClosed) Connect();
            if (!HidD_SetOutputReport(_dev, report, report.Length))
                throw new IOException("HidD_SetOutputReport failed (error " + Marshal.GetLastWin32Error() + ")");
        }

        static void Begin() { Send(Packet(0x01)); }
        static void End()   { Send(Packet(0x02)); }

        static void Transaction(params byte[][] cmds)
        {
            Begin();
            foreach (var c in cmds) Send(Packet(c));
            End();
        }

        // Overlapped interrupt-pipe read with timeout; returns null on timeout.
        static byte[] ReadInput(int timeoutMs)
        {
            var buf = new byte[ReportLen + 1];
            var ov = new NativeOverlapped();
            ov.EventHandle = CreateEvent(IntPtr.Zero, true, false, IntPtr.Zero);
            try
            {
                if (!ReadFile(_dev, buf, buf.Length, IntPtr.Zero, ref ov))
                {
                    if (Marshal.GetLastWin32Error() != 997 /* ERROR_IO_PENDING */)
                        throw new IOException("ReadFile failed (error " + Marshal.GetLastWin32Error() + ")");
                    if (WaitForSingleObject(ov.EventHandle, (uint)timeoutMs) != 0)
                    {
                        CancelIo(_dev);
                        return null;
                    }
                }
                int n;
                if (!GetOverlappedResult(_dev, ref ov, out n, true)) return null;
                var outBuf = new byte[n];
                Array.Copy(buf, outBuf, n);
                return outBuf;
            }
            finally { CloseHandle(ov.EventHandle); }
        }

        // Device info query. Reply byte [18] is the active profile (0-based).
        public static byte[] ReadState()
        {
            if (_dev == null || _dev.IsInvalid || _dev.IsClosed) Connect();
            HidD_FlushQueue(_dev);
            Send(Packet(0x03, 0x2C));
            return ReadInput(1000);
        }

        // Read a profile's LED settings (profile 0..2). Reply layout:
        //   [8] mode  [9] brightness  [10] speed(inverted: 3-x)  [11] direction
        //   [12] rainbow flag  [13..15] R,G,B
        public static byte[] ReadLedSettings(byte profile)
        {
            if (_dev == null || _dev.IsInvalid || _dev.IsClosed) Connect();
            HidD_FlushQueue(_dev);
            Send(Packet(0x05, 0x38, (byte)(profile * 0x2A)));
            return ReadInput(1000);
        }

        public static void SetMode(byte mode)        { Transaction(new byte[] { 0x06, 0x01, 0x00, 0x00, 0x00, mode }); }
        public static void SetBrightness(byte level) { Transaction(new byte[] { 0x06, 0x01, 0x01, 0x00, 0x00, level }); }
        public static void SetSpeed(byte speed)      { Transaction(new byte[] { 0x06, 0x01, 0x02, 0x00, 0x00, speed }); }
        public static void SetColor(byte r, byte g, byte b)
        {
            Transaction(new byte[] { 0x06, 0x03, 0x05, 0x00, 0x00, r, g, b });
        }

        // Static color = "fixed" mode (0x06) + color, in one transaction.
        public const byte ModeFixed = 0x06;
        public static void SetStatic(byte r, byte g, byte b)
        {
            Transaction(
                new byte[] { 0x06, 0x01, 0x00, 0x00, 0x00, ModeFixed },
                new byte[] { 0x06, 0x03, 0x05, 0x00, 0x00, r, g, b });
        }
    }
}
