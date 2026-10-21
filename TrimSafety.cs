using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;
using System.Diagnostics;

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
    public interface ITrimObservation { ObservationSnapshot Observe(IntPtr handle); }
    public sealed class ObservationSnapshot {
        public string Utc, Status="unavailable";
        public double Seconds, DurationMs;
        public Dictionary<string,ulong?> Bytes=new Dictionary<string,ulong?>();
        public double? SelfCpuSeconds;
    }
    public sealed class TrimReceipt {
        public string Schema="ram-neko.trim-receipt", AttemptId=Guid.NewGuid().ToString("N");
        public int Version=1;
        public CandidateIdentity Identity;
        public ObservationSnapshot Before, After;
    }
    public static class TrimGuard {
        public static void Execute(CandidateIdentity expected, ITrimNative native) {
            ExecuteCore(expected,native,false);
        }
        static ObservationSnapshot Observe(ITrimNative native,IntPtr handle) {
            try { var source=native as ITrimObservation; if(source!=null) return source.Observe(handle); } catch { }
            return new ObservationSnapshot {Utc=DateTime.UtcNow.ToString("o"),Seconds=Stopwatch.GetTimestamp()/(double)Stopwatch.Frequency};
        }
        public static TrimReceipt ExecuteObserved(CandidateIdentity expected, ITrimNative native) {
            return ExecuteCore(expected,native,true);
        }
        static TrimReceipt ExecuteCore(CandidateIdentity expected,ITrimNative native,bool observe) {
            if (expected == null || native == null) throw new ArgumentNullException();
            IntPtr handle = native.Open(expected.Id);
            if (handle == IntPtr.Zero) throw new InvalidOperationException("identity_open_failed");
            try {
                CandidateIdentity actual = native.ReadIdentity(handle);
                if (actual == null || actual.Id != expected.Id || actual.StartUtcTicks != expected.StartUtcTicks ||
                    actual.SessionId != expected.SessionId || !String.Equals(actual.Name, expected.Name, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("identity_mismatch");
                // The exact verified handle is used for the mutation. No PID reopen.
                var receipt=observe?new TrimReceipt {Identity=expected,Before=Observe(native,handle)}:null;
                native.Empty(handle);
                if(observe) receipt.After=Observe(native,handle);
                return receipt;
            } finally { native.Close(handle); }
        }
    }
    public sealed class WindowsTrimNative : ITrimNative, ITrimObservation {
        // Optional synchronous foreground recheck supplied by the existing host action path.
        public Action BeforeEmpty;
        [StructLayout(LayoutKind.Sequential)] struct Counters {public uint Size,Faults;public UIntPtr Peak,Working,PagedPeak,Paged,NonPagedPeak,NonPaged,Pagefile,PagefilePeak,Private;}
        [StructLayout(LayoutKind.Sequential)] struct Io {public ulong Reads,Writes,Other,ReadBytes,WriteBytes,OtherBytes;}
        [StructLayout(LayoutKind.Sequential)] struct Memory {public uint Size,Load;public ulong Total,Available,TotalPage,AvailablePage,TotalVirtual,AvailableVirtual,Extended;}
        [StructLayout(LayoutKind.Sequential)] struct Performance {public uint Size;public UIntPtr Commit,Limit,Peak,Physical,Available,Cache,Kernel,Paged,Nonpaged,PageSize;public uint Handles,Processes,Threads;}
        [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, int id);
        [DllImport("kernel32.dll", SetLastError=true)] static extern uint GetProcessId(IntPtr process);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr process, out uint code);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessTimes(IntPtr process, out long creation, out long exit, out long kernel, out long user);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool QueryFullProcessImageNameW(IntPtr process, uint flags, StringBuilder name, ref uint size);
        [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
        [DllImport("advapi32.dll", SetLastError=true)] static extern bool GetTokenInformation(IntPtr token, int infoClass, out int sessionId, int length, out int returned);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool K32EmptyWorkingSet(IntPtr process);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool K32GetProcessMemoryInfo(IntPtr process,ref Counters counters,uint size);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessIoCounters(IntPtr process,out Io io);
        [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool GlobalMemoryStatusEx(ref Memory memory);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool K32GetPerformanceInfo(ref Performance info,uint size);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        static void Check(bool success, string operation) {
            if (!success) throw new Win32Exception(Marshal.GetLastWin32Error(), operation);
        }
        public IntPtr Open(int id) {
            // Same process rights as before: QUERY_INFORMATION | SET_QUOTA.
            IntPtr handle = OpenProcess(0x0500, false, id);
            Check(handle != IntPtr.Zero, "identity_open_failed"); return handle;
        }
        public IntPtr OpenReadOnly(int id) {
            IntPtr handle=OpenProcess(0x0400,false,id); // QUERY_INFORMATION, never SET_QUOTA
            Check(handle!=IntPtr.Zero,"observation_open_failed");return handle;
        }
        static void ObserveProcess(IntPtr handle,string prefix,ObservationSnapshot sample) {
            Counters c=new Counters();c.Size=(uint)Marshal.SizeOf(c);
            bool memory=K32GetProcessMemoryInfo(handle,ref c,c.Size);
            sample.Bytes[prefix+"working_set_bytes"]=memory?(ulong?)c.Working.ToUInt64():null;
            sample.Bytes[prefix+"private_bytes"]=memory?(ulong?)c.Private.ToUInt64():null;
            Io io;bool available=GetProcessIoCounters(handle,out io);
            sample.Bytes[prefix+"logical_read_bytes_total"]=available?(ulong?)io.ReadBytes:null;
            sample.Bytes[prefix+"logical_write_bytes_total"]=available?(ulong?)io.WriteBytes:null;
        }
        public ObservationSnapshot Observe(IntPtr handle) {
            var watch=Stopwatch.StartNew();
            var sample=new ObservationSnapshot {Utc=DateTime.UtcNow.ToString("o"),Seconds=Stopwatch.GetTimestamp()/(double)Stopwatch.Frequency,Status="ok"};
            ObserveProcess(handle,"target.",sample);ObserveProcess(GetCurrentProcess(),"self.",sample);
            Memory memory=new Memory();memory.Size=(uint)Marshal.SizeOf(memory);
            sample.Bytes["physical.available_bytes"]=GlobalMemoryStatusEx(ref memory)?(ulong?)memory.Available:null;
            Performance info=new Performance();info.Size=(uint)Marshal.SizeOf(info);
            bool perf=K32GetPerformanceInfo(ref info,info.Size);
            sample.Bytes["commit.used_bytes"]=perf?(ulong?)checked(info.Commit.ToUInt64()*info.PageSize.ToUInt64()):null;
            sample.Bytes["commit.limit_bytes"]=perf?(ulong?)checked(info.Limit.ToUInt64()*info.PageSize.ToUInt64()):null;
            long creation,exit,kernel,user;
            sample.SelfCpuSeconds=GetProcessTimes(GetCurrentProcess(),out creation,out exit,out kernel,out user)?(double?)(kernel/10000000.0+user/10000000.0):null;
            foreach(var value in sample.Bytes.Values) if(!value.HasValue)sample.Status="partial";
            sample.DurationMs=watch.Elapsed.TotalMilliseconds;return sample;
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
        public void Empty(IntPtr handle) { if(BeforeEmpty!=null)BeforeEmpty();Check(K32EmptyWorkingSet(handle), "empty_working_set_failed"); }
        public void Close(IntPtr handle) { CloseHandle(handle); }
    }
}
