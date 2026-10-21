using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace RamNeko.Safety {
    // Values captured during candidate selection; never refreshed by PID.
    public sealed class CandidateIdentity {
        public readonly int Id, SessionId;
        public readonly long StartUtcTicks;
        public readonly string Name;
        public CandidateIdentity(int id, long startUtcTicks, string name, int sessionId) {
            if (id <= 0 || startUtcTicks <= 0 || String.IsNullOrEmpty(name) || sessionId < 0)
                throw new ArgumentException("Invalid candidate identity");
            Id = id; StartUtcTicks = startUtcTicks; Name = name; SessionId = sessionId;
        }
    }
    public interface ITrimNative {
        IntPtr Open(int id);
        CandidateIdentity ReadIdentity(IntPtr handle);
        void Empty(IntPtr handle);
        void Close(IntPtr handle);
    }
    public static class TrimGuard {
        public static void Execute(CandidateIdentity expected, ITrimNative native) {
            if (expected == null || native == null) throw new ArgumentNullException();
            IntPtr handle = native.Open(expected.Id);
            if (handle == IntPtr.Zero) throw new InvalidOperationException("identity_open_failed");
            try {
                CandidateIdentity actual = native.ReadIdentity(handle);
                if (actual == null || actual.Id != expected.Id || actual.StartUtcTicks != expected.StartUtcTicks ||
                    actual.SessionId != expected.SessionId || !String.Equals(actual.Name, expected.Name, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("identity_mismatch");
                // The exact verified handle is used for the mutation. No PID reopen.
                native.Empty(handle);
            } finally { native.Close(handle); }
        }
    }
    public sealed class WindowsTrimNative : ITrimNative {
        [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, int id);
        [DllImport("kernel32.dll", SetLastError=true)] static extern uint GetProcessId(IntPtr process);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr process, out uint code);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessTimes(IntPtr process, out long creation, out long exit, out long kernel, out long user);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool QueryFullProcessImageNameW(IntPtr process, uint flags, StringBuilder name, ref uint size);
        [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
        [DllImport("advapi32.dll", SetLastError=true)] static extern bool GetTokenInformation(IntPtr token, int infoClass, out int sessionId, int length, out int returned);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool K32EmptyWorkingSet(IntPtr process);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        static void Check(bool success, string operation) {
            if (!success) throw new Win32Exception(Marshal.GetLastWin32Error(), operation);
        }
        public IntPtr Open(int id) {
            // Same process rights as before: QUERY_INFORMATION | SET_QUOTA.
            IntPtr handle = OpenProcess(0x0500, false, id);
            Check(handle != IntPtr.Zero, "identity_open_failed"); return handle;
        }
        public CandidateIdentity ReadIdentity(IntPtr handle) {
            long creation, exit, kernel, user;
            Check(GetProcessTimes(handle, out creation, out exit, out kernel, out user), "identity_times_failed");
            // GetProcessTimes exit FILETIME is undefined while running; do not interpret it.
            uint exitCode;
            Check(GetExitCodeProcess(handle, out exitCode), "identity_exit_state_failed");
            if (exitCode != 259) throw new InvalidOperationException("identity_process_exited"); // STILL_ACTIVE
            uint id = GetProcessId(handle); Check(id != 0, "identity_pid_failed");
            uint size = 32768; StringBuilder path = new StringBuilder((int)size);
            Check(QueryFullProcessImageNameW(handle, 0, path, ref size), "identity_image_failed");
            IntPtr token;
            Check(OpenProcessToken(handle, 0x0008, out token), "identity_token_failed"); // TOKEN_QUERY only
            int session, returned;
            try {
                Check(GetTokenInformation(token, 12, out session, 4, out returned), "identity_session_failed"); // TokenSessionId
                if (returned != 4) throw new InvalidOperationException("identity_session_size");
            } finally { CloseHandle(token); }
            return new CandidateIdentity(checked((int)id), DateTime.FromFileTimeUtc(creation).Ticks,
                Path.GetFileNameWithoutExtension(path.ToString()), session);
        }
        public void Empty(IntPtr handle) { Check(K32EmptyWorkingSet(handle), "empty_working_set_failed"); }
        public void Close(IntPtr handle) { CloseHandle(handle); }
    }
}
