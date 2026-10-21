using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

namespace RamNeko.Diagnostics {
    public sealed class Metric {
        public object Value; public string Unit, Source, Status, Reason;
        public static Metric Ok(object value,string unit,string source) { return new Metric {Value=value,Unit=unit,Source=source,Status="ok"}; }
        public static Metric Missing(string unit,string source,string reason,string status="unavailable") { return new Metric {Value=null,Unit=unit,Source=source,Status=status,Reason=reason}; }
    }
    public sealed class ProcessSample {
        public int Id; public string Name,StartUtc; public long WorkingSetBytes,PrivateBytes;
    }
    public sealed class RawSnapshot {
        public Dictionary<string,Metric> Metrics=new Dictionary<string,Metric>();
        public ulong? Idle,Kernel,User,SelfReadBytes,SelfWriteBytes;
        public double? SelfCpuSeconds;
        public int ProcessorCount=Environment.ProcessorCount;
        public List<ProcessSample> Processes=new List<ProcessSample>();
        public string ProcessStatus="unavailable"; public int UnreadableProcesses;
    }
    public interface IDiagnosticSource : IDisposable { RawSnapshot Read(); }
    public interface IDiagnosticClock { DateTime UtcNow {get;} double Seconds {get;} }
    public sealed class DiagnosticClock : IDiagnosticClock {
        readonly Stopwatch watch=Stopwatch.StartNew();
        public DateTime UtcNow {get{return DateTime.UtcNow;}} public double Seconds {get{return watch.Elapsed.TotalSeconds;}}
    }
    public sealed class DiagnosticSample {
        public string Schema="ram-neko.diagnostics"; public int Version=1;
        public long Sequence; public string Utc; public int IntervalSeconds;
        public bool ObservationOnly=true;
        public double? ElapsedSeconds;
        public Dictionary<string,Metric> Metrics;
        public ProcessSample[] Processes;
        public string ProcessCollectionStatus; public int UnreadableProcesses;
        public double CollectionDurationMs;
    }
    public sealed class DiagnosticSampler : IDisposable {
        readonly IDiagnosticSource source; readonly IDiagnosticClock clock;
        readonly int interval; RawSnapshot previous; double? previousSeconds; long sequence;
        public DiagnosticSampler(IDiagnosticSource source,IDiagnosticClock clock,int intervalSeconds) {
            if(source==null||clock==null||intervalSeconds<1) throw new ArgumentException("Invalid sampler configuration");
            this.source=source;this.clock=clock;interval=intervalSeconds;
        }
        public static ulong PagesToBytes(ulong pages,ulong size) { return checked(pages*size); }
        static Metric Rate(ulong? now,ulong? before,double? elapsed,string unit,string origin) {
            if(!now.HasValue) return Metric.Missing(unit,origin,"provider_unavailable");
            if(!before.HasValue||!elapsed.HasValue) return Metric.Missing(unit,origin,"needs_previous_sample","warmup");
            if(elapsed.Value<=0||now.Value<before.Value) return Metric.Missing(unit,origin,"counter_or_clock_reset");
            return Metric.Ok((now.Value-before.Value)/elapsed.Value,unit,origin);
        }
        static double? Numeric(RawSnapshot raw,string key) {
            Metric m;
            return raw!=null&&raw.Metrics.TryGetValue(key,out m)&&m.Status=="ok"&&m.Value!=null ? (double?)Convert.ToDouble(m.Value) : null;
        }
        public DiagnosticSample Sample() {
            var watch=Stopwatch.StartNew(); RawSnapshot raw;
            try { raw=source.Read()??new RawSnapshot(); }
            catch { raw=new RawSnapshot();raw.ProcessStatus="provider_error"; }
            double seconds=clock.Seconds;
            double? elapsed=previousSeconds.HasValue?(double?)(seconds-previousSeconds.Value):null;
            bool timingValid=elapsed.HasValue&&elapsed>0&&elapsed<=interval*3.0;
            var metrics=new Dictionary<string,Metric>(raw.Metrics);
            foreach(var key in new[]{"physical.total_bytes","physical.available_bytes","commit.used_bytes","commit.limit_bytes","commit.peak_bytes"})
                if(!metrics.ContainsKey(key)) metrics[key]=Metric.Missing("bytes",key.StartsWith("commit.")?"GetPerformanceInfo":"GlobalMemoryStatusEx","provider_unavailable");
            foreach(var key in new[]{"paging.total_faults_per_second","paging.read_operations_per_second","paging.input_pages_per_second","disk.read_bytes_per_second","disk.write_bytes_per_second"})
                if(!metrics.ContainsKey(key)) metrics[key]=Metric.Missing(key.StartsWith("disk.")?"bytes/s":key.Contains("input_pages")?"pages/s":"events/s","PDH","provider_unavailable");
            foreach(var key in new[]{"self.working_set_bytes","self.private_bytes"})
                if(!metrics.ContainsKey(key)) metrics[key]=Metric.Missing("bytes","Process","provider_unavailable");
            if(!metrics.ContainsKey("memory.os_low")) metrics["memory.os_low"]=Metric.Missing("boolean","QueryMemoryResourceNotification","provider_unavailable");
            Metric cpu=Metric.Missing("percent","GetSystemTimes","needs_previous_sample","warmup");
            if(!raw.Idle.HasValue||!raw.Kernel.HasValue||!raw.User.HasValue) cpu=Metric.Missing("percent","GetSystemTimes","provider_or_processor_group_unavailable");
            else if(previous!=null&&timingValid&&previous.Idle.HasValue&&previous.Kernel.HasValue&&previous.User.HasValue) {
                if(raw.Idle>=previous.Idle&&raw.Kernel>=previous.Kernel&&raw.User>=previous.User) {
                    double total=(double)(raw.Kernel.Value-previous.Kernel.Value)+(raw.User.Value-previous.User.Value);
                    double idle=raw.Idle.Value-previous.Idle.Value;
                    cpu=total>0&&idle<=total?Metric.Ok(100*(total-idle)/total,"percent","GetSystemTimes"):Metric.Missing("percent","GetSystemTimes","invalid_delta");
                } else cpu=Metric.Missing("percent","GetSystemTimes","counter_reset");
            }
            if(elapsed.HasValue&&!timingValid) cpu=Metric.Missing("percent","GetSystemTimes","invalid_sampling_interval");
            metrics["cpu.system_percent"]=cpu;
            metrics["paging.hard_faults_per_second"]=Metric.Missing("faults/s","not_collected","exact_hard_fault_count_requires_separate_instrumentation");
            metrics["interaction.app_switch_ms"]=Metric.Missing("ms","not_collected","responsiveness_not_instrumented_in_m1");
            metrics["self.io_read_bytes_per_second"]=Rate(raw.SelfReadBytes,previous==null?null:previous.SelfReadBytes,timingValid?elapsed:null,"bytes/s","GetProcessIoCounters.logical_io");
            metrics["self.io_write_bytes_per_second"]=Rate(raw.SelfWriteBytes,previous==null?null:previous.SelfWriteBytes,timingValid?elapsed:null,"bytes/s","GetProcessIoCounters.logical_io");
            Metric own=Metric.Missing("percent","Process.TotalProcessorTime","provider_unavailable");
            if(raw.SelfCpuSeconds.HasValue) {
                own=Metric.Missing("percent","Process.TotalProcessorTime","needs_previous_sample","warmup");
                if(previous!=null&&previous.SelfCpuSeconds.HasValue&&timingValid) {
                    double delta=raw.SelfCpuSeconds.Value-previous.SelfCpuSeconds.Value;
                    own=delta>=0&&raw.ProcessorCount>0?Metric.Ok(100*delta/elapsed.Value/raw.ProcessorCount,"percent","Process.TotalProcessorTime"):Metric.Missing("percent","Process.TotalProcessorTime","counter_reset");
                }
            }
            metrics["self.cpu_percent"]=own;
            foreach(var key in new[]{"physical.available_bytes","commit.used_bytes"}) {
                var a=Numeric(raw,key);var b=Numeric(previous,key);
                metrics[key+"_per_second"]=a.HasValue&&b.HasValue&&timingValid ? Metric.Ok((a.Value-b.Value)/elapsed.Value,"bytes/s","sample_delta") : Metric.Missing("bytes/s","sample_delta","needs_valid_sample_pair","warmup");
            }
            previous=raw;previousSeconds=seconds;
            return new DiagnosticSample {Sequence=++sequence,Utc=clock.UtcNow.ToString("o"),IntervalSeconds=interval,ElapsedSeconds=timingValid?elapsed:null,
                Metrics=metrics,Processes=raw.Processes.ToArray(),ProcessCollectionStatus=raw.ProcessStatus,UnreadableProcesses=raw.UnreadableProcesses,CollectionDurationMs=watch.Elapsed.TotalMilliseconds};
        }
        public void Dispose(){source.Dispose();}
    }

    public sealed class NativeDiagnosticSource : IDiagnosticSource {
        [StructLayout(LayoutKind.Sequential)] struct Memory { public uint Length,Load;public ulong Total,Available,TotalPage,AvailablePage,TotalVirtual,AvailableVirtual,Extended; }
        [StructLayout(LayoutKind.Sequential)] struct Performance { public uint Size;public UIntPtr Commit,Limit,Peak,Physical,Available,Cache,Kernel,Paged,Nonpaged,PageSize;public uint Handles,Processes,Threads; }
        [StructLayout(LayoutKind.Sequential)] struct FileTime {public uint Low,High;public ulong Value {get{return ((ulong)High<<32)|Low;}}}
        [StructLayout(LayoutKind.Sequential)] struct Io { public ulong ReadOperations,WriteOperations,OtherOperations,ReadBytes,WriteBytes,OtherBytes; }
        [StructLayout(LayoutKind.Explicit)] struct CounterValue { [FieldOffset(0)]public uint Status;[FieldOffset(8)]public double Value; }
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool GlobalMemoryStatusEx(ref Memory value);
        [DllImport("psapi.dll",SetLastError=true)] static extern bool GetPerformanceInfo(out Performance value,uint size);
        [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr CreateMemoryResourceNotification(int kind);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool QueryMemoryResourceNotification(IntPtr handle,out bool state);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetSystemTimes(out FileTime idle,out FileTime kernel,out FileTime user);
        [DllImport("kernel32.dll")] static extern ushort GetActiveProcessorGroupCount();
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetProcessIoCounters(IntPtr handle,out Io io);
        [DllImport("pdh.dll",CharSet=CharSet.Unicode)] static extern uint PdhOpenQuery(string source,UIntPtr data,out IntPtr query);
        [DllImport("pdh.dll",CharSet=CharSet.Unicode)] static extern uint PdhAddEnglishCounterW(IntPtr query,string path,UIntPtr data,out IntPtr counter);
        [DllImport("pdh.dll")] static extern uint PdhCollectQueryData(IntPtr query);
        [DllImport("pdh.dll")] static extern uint PdhGetFormattedCounterValue(IntPtr counter,uint format,out uint type,out CounterValue value);
        [DllImport("pdh.dll")] static extern uint PdhCloseQuery(IntPtr query);
        readonly Dictionary<string,IntPtr> counters=new Dictionary<string,IntPtr>();
        readonly Dictionary<string,string> counterErrors=new Dictionary<string,string>();
        IntPtr query,low;bool primed;
        public NativeDiagnosticSource() {
            low=CreateMemoryResourceNotification(0);
            uint status=PdhOpenQuery(null,UIntPtr.Zero,out query);
            var paths=new Dictionary<string,string> {
                {"paging.total_faults_per_second",@"\Memory\Page Faults/sec"},
                {"paging.read_operations_per_second",@"\Memory\Page Reads/sec"},
                {"paging.input_pages_per_second",@"\Memory\Pages Input/sec"},
                {"disk.read_bytes_per_second",@"\PhysicalDisk(_Total)\Disk Read Bytes/sec"},
                {"disk.write_bytes_per_second",@"\PhysicalDisk(_Total)\Disk Write Bytes/sec"}
            };
            foreach(var pair in paths) {
                IntPtr h=IntPtr.Zero;uint s=status==0?PdhAddEnglishCounterW(query,pair.Value,UIntPtr.Zero,out h):status;
                if(s==0)counters[pair.Key]=h;else counterErrors[pair.Key]="pdh_"+s.ToString("X8");
            }
        }
        public RawSnapshot Read() {
            var raw=new RawSnapshot();var m=new Memory();m.Length=(uint)Marshal.SizeOf(typeof(Memory));
            if(GlobalMemoryStatusEx(ref m)) {
                raw.Metrics["physical.total_bytes"]=Metric.Ok(m.Total,"bytes","GlobalMemoryStatusEx");
                raw.Metrics["physical.available_bytes"]=Metric.Ok(m.Available,"bytes","GlobalMemoryStatusEx");
            }
            Performance p;
            if(GetPerformanceInfo(out p,(uint)Marshal.SizeOf(typeof(Performance)))) {
                try {
                    ulong page=p.PageSize.ToUInt64();
                    raw.Metrics["commit.used_bytes"]=Metric.Ok(DiagnosticSampler.PagesToBytes(p.Commit.ToUInt64(),page),"bytes","GetPerformanceInfo");
                    raw.Metrics["commit.limit_bytes"]=Metric.Ok(DiagnosticSampler.PagesToBytes(p.Limit.ToUInt64(),page),"bytes","GetPerformanceInfo");
                    raw.Metrics["commit.peak_bytes"]=Metric.Ok(DiagnosticSampler.PagesToBytes(p.Peak.ToUInt64(),page),"bytes","GetPerformanceInfo");
                } catch(OverflowException) { }
            }
            bool state;
            raw.Metrics["memory.os_low"]=low!=IntPtr.Zero&&QueryMemoryResourceNotification(low,out state)?Metric.Ok(state,"boolean","QueryMemoryResourceNotification"):Metric.Missing("boolean","QueryMemoryResourceNotification","win32_unavailable");
            FileTime idle,kernel,user;
            if(GetActiveProcessorGroupCount()==1&&GetSystemTimes(out idle,out kernel,out user)){raw.Idle=idle.Value;raw.Kernel=kernel.Value;raw.User=user.Value;}
            uint collected=query==IntPtr.Zero?0xC0000BBC:PdhCollectQueryData(query);
            foreach(var pair in counterErrors) raw.Metrics[pair.Key]=Metric.Missing(CounterUnit(pair.Key),"PDH",pair.Value);
            foreach(var pair in counters) {
                // PDH_FMT_DOUBLE | PDH_FMT_NOCAP100: rates must not be percentage-capped.
                uint type;CounterValue value;uint result=PdhGetFormattedCounterValue(pair.Value,0x200|0x8000,out type,out value);
                if(!primed)raw.Metrics[pair.Key]=Metric.Missing(CounterUnit(pair.Key),"PDH","needs_previous_sample","warmup");
                else if(collected!=0||result!=0||value.Status>1)raw.Metrics[pair.Key]=Metric.Missing(CounterUnit(pair.Key),"PDH","pdh_"+(collected!=0?collected:result!=0?result:value.Status).ToString("X8"));
                else if(value.Value<0||double.IsNaN(value.Value)||double.IsInfinity(value.Value))raw.Metrics[pair.Key]=Metric.Missing(CounterUnit(pair.Key),"PDH","invalid_numeric_value");
                else raw.Metrics[pair.Key]=Metric.Ok(value.Value,CounterUnit(pair.Key),"PDH");
            }
            primed=collected==0;
            using(var self=Process.GetCurrentProcess()) {
                try {
                    raw.SelfCpuSeconds=self.TotalProcessorTime.TotalSeconds;
                    raw.Metrics["self.working_set_bytes"]=Metric.Ok(self.WorkingSet64,"bytes","Process.WorkingSet64");
                    raw.Metrics["self.private_bytes"]=Metric.Ok(self.PrivateMemorySize64,"bytes","Process.PrivateMemorySize64");
                    Io io;if(GetProcessIoCounters(self.Handle,out io)){raw.SelfReadBytes=io.ReadBytes;raw.SelfWriteBytes=io.WriteBytes;}
                } catch { }
            }
            Process[] processes=new Process[0];var candidates=new List<KeyValuePair<Process,long>>();
            try {
                processes=Process.GetProcesses();
                foreach(var process in processes) {try{candidates.Add(new KeyValuePair<Process,long>(process,process.WorkingSet64));}catch{raw.UnreadableProcesses++;}}
                foreach(var pair in candidates.OrderByDescending(x=>x.Value).Take(5)) {
                    try { raw.Processes.Add(new ProcessSample {Id=pair.Key.Id,Name=pair.Key.ProcessName,StartUtc=pair.Key.StartTime.ToUniversalTime().ToString("o"),WorkingSetBytes=pair.Value,PrivateBytes=pair.Key.PrivateMemorySize64}); }
                    catch { raw.UnreadableProcesses++; }
                }
                raw.ProcessStatus=raw.UnreadableProcesses==0?"ok":"partial";
            } catch {raw.ProcessStatus="unavailable";} finally {foreach(var process in processes)process.Dispose();}
            return raw;
        }
        static string CounterUnit(string key) {return key.StartsWith("disk.")?"bytes/s":key.Contains("input_pages")?"pages/s":"events/s";}
        public void Dispose(){if(query!=IntPtr.Zero){PdhCloseQuery(query);query=IntPtr.Zero;}if(low!=IntPtr.Zero){CloseHandle(low);low=IntPtr.Zero;}}
    }

    public sealed class DiagnosticEngine : IDisposable {
        readonly object gate=new object();readonly ManualResetEvent stop=new ManualResetEvent(false);
        readonly Thread worker;readonly string directory;readonly int interval;
        readonly Func<IDiagnosticSource> sourceFactory;
        string latest,error;long writes;bool disposed,exited;
        public string LatestJson {get{lock(gate)return latest;}}
        public string LastError {get{lock(gate)return error;}} public long LogWrites {get{return Interlocked.Read(ref writes);}}
        public bool WorkerAlive {get{return worker.IsAlive;}}
        public DiagnosticEngine(string directory,int intervalSeconds=60):this(directory,intervalSeconds,delegate{return new NativeDiagnosticSource();}) { }
        public DiagnosticEngine(string directory,int intervalSeconds,Func<IDiagnosticSource> factory) {
            if(intervalSeconds<10||intervalSeconds>3600)throw new ArgumentOutOfRangeException("intervalSeconds");
            if(factory==null)throw new ArgumentNullException("factory");
            this.directory=directory;interval=intervalSeconds;sourceFactory=factory;
            worker=new Thread(Run);worker.IsBackground=true;worker.Name="RAM NEKO observation-only diagnostics";worker.Start();
        }
        public static void AppendBounded(string path,string json,long limit=5242880) {
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            var encoding=new UTF8Encoding(false);string line=json+Environment.NewLine;
            long bytes=encoding.GetByteCount(line);
            if(bytes>limit)throw new ArgumentException("Diagnostic record exceeds log capacity");
            if(new FileInfo(path).Exists&&new FileInfo(path).Length+bytes>limit){if(File.Exists(path+".1"))File.Delete(path+".1");File.Move(path,path+".1");}
            File.AppendAllText(path,line,encoding);
        }
        void Run() {
            try {
                using(var sampler=new DiagnosticSampler(sourceFactory(),new DiagnosticClock(),interval)) {
                    var serializer=new JavaScriptSerializer();
                    do {
                        try {
                            var sample=sampler.Sample();string json=serializer.Serialize(sample);
                            lock(gate){latest=json;error=null;}
                            try {AppendBounded(Path.Combine(directory,"diagnostics.jsonl"),json);Interlocked.Increment(ref writes);}
                            catch(Exception ex){lock(gate)error="log_io: "+ex.GetType().Name;}
                        }catch(Exception ex){lock(gate)error="collection: "+ex.GetType().Name;}
                    }while(!stop.WaitOne(interval*1000));
                }
            }catch(Exception ex){lock(gate)error="initialization: "+ex.GetType().Name;}
            finally{lock(gate){exited=true;if(disposed)stop.Dispose();}}
        }
        public void Dispose(){lock(gate){if(disposed)return;disposed=true;if(exited)stop.Dispose();else stop.Set();}}
        public bool WaitForStop(int milliseconds){return worker.Join(milliseconds);}
    }
}
