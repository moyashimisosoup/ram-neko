using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Threading;
using System.Web.Script.Serialization;

namespace RamNeko.Safety {
    public interface IObservationClock { double Seconds {get;} DateTime UtcNow {get;} }
    public sealed class ObservationClock : IObservationClock {
        public double Seconds {get{return Stopwatch.GetTimestamp()/(double)Stopwatch.Frequency;}}
        public DateTime UtcNow {get{return DateTime.UtcNow;}}
    }
    public interface ITargetObservationSource { ObservationSnapshot Read(CandidateIdentity identity); }
    public sealed class NativeTargetObservationSource : ITargetObservationSource {
        public ObservationSnapshot Read(CandidateIdentity expected) {
            var native=new WindowsTrimNative();IntPtr handle=native.OpenReadOnly(expected.Id);
            try {
                Validate(expected,native.ReadIdentity(handle));
                var sample=native.Observe(handle);
                Validate(expected,native.ReadIdentity(handle));
                return sample;
            } finally {native.Close(handle);}
        }
        static void Validate(CandidateIdentity expected,CandidateIdentity actual) {
            if(actual.Id!=expected.Id||actual.StartUtcTicks!=expected.StartUtcTicks||actual.SessionId!=expected.SessionId||
                !String.Equals(actual.Name,expected.Name,StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("observation_identity_mismatch");
        }
    }
    // Mutable wire types only; the scheduler reconstructs immutable candidate identities.
    public sealed class ReceiptIdentity {public int Id,SessionId;public long StartUtcTicks;public string Name;}
    public sealed class ObservationReceipt {
        public string Schema,AttemptId;public int Version;public ReceiptIdentity Identity;
        public ObservationSnapshot Before,After;
    }
    public sealed class ObservationRecord {
        public string Schema="ram-neko.post-trim";public int Version=1;public bool ObservationOnly=true;
        public string AttemptId,Phase,Utc,Status,Reason;
        public CandidateIdentity Identity;
        public double PlannedOffsetSeconds,ActualElapsedSeconds,LatenessSeconds;
        public ObservationSnapshot Snapshot;
        public object DiagnosticContext;
        public Dictionary<string,double?> Changes=new Dictionary<string,double?>();
    }
    public sealed class PostTrimScheduler {
        sealed class Job {public ObservationReceipt Receipt;public CandidateIdentity Identity;public int Stage;public bool BaselinesWritten;}
        readonly object gate=new object();readonly List<Job> jobs=new List<Job>();
        readonly IObservationClock clock;readonly ITargetObservationSource source;readonly Action<ObservationRecord> write;readonly Func<string> context;
        bool stopped;public int WriteFailures {get;private set;}
        public int Pending {get{lock(gate)return jobs.Count;}}
        public const int MaximumPending=12;
        public const double DeadlineToleranceSeconds=10;
        public PostTrimScheduler(IObservationClock clock,ITargetObservationSource source,Action<ObservationRecord> write,Func<string> context=null) {
            if(clock==null||source==null||write==null)throw new ArgumentNullException();
            this.clock=clock;this.source=source;this.write=write;this.context=context;
        }
        static bool ValidSnapshot(ObservationSnapshot sample) {
            DateTime utc;
            return sample!=null&&sample.Bytes!=null&&sample.Bytes.Count<=16&&sample.Seconds>0&&!Double.IsNaN(sample.Seconds)&&!Double.IsInfinity(sample.Seconds)&&
                DateTime.TryParse(sample.Utc,CultureInfo.InvariantCulture,DateTimeStyles.RoundtripKind,out utc)&&utc.Kind==DateTimeKind.Utc;
        }
        public string Enqueue(string json) {
            ObservationReceipt receipt;CandidateIdentity identity;
            try {
                if(json==null||json.Length>16384)return "invalid_receipt";
                receipt=new JavaScriptSerializer().Deserialize<ObservationReceipt>(json);
                Guid id;
                if(receipt==null||receipt.Schema!="ram-neko.trim-receipt"||receipt.Version!=1||!Guid.TryParseExact(receipt.AttemptId,"N",out id)||
                    !ValidSnapshot(receipt.Before)||!ValidSnapshot(receipt.After)||receipt.After.Seconds<receipt.Before.Seconds)return "invalid_receipt";
                identity=new CandidateIdentity(receipt.Identity.Id,receipt.Identity.StartUtcTicks,receipt.Identity.Name,receipt.Identity.SessionId);
                double age=clock.Seconds-receipt.After.Seconds;
                if(age<0||age>5)return "stale_receipt";
            } catch {return "invalid_receipt";}
            lock(gate) {
                if(stopped)return "stopped";
                foreach(var job in jobs)if(job.Receipt.AttemptId==receipt.AttemptId)return "duplicate_receipt";
                if(jobs.Count>=MaximumPending)return "queue_full";
                jobs.Add(new Job {Receipt=receipt,Identity=identity});return "accepted";
            }
        }
        object Context(DateTime phaseUtc) {
            if(context==null)return new {Status="unavailable",Reason="diagnostics_disabled"};
            try {
                var raw=new JavaScriptSerializer().DeserializeObject(context()) as Dictionary<string,object>;
                DateTime utc=DateTime.Parse((string)raw["Utc"],CultureInfo.InvariantCulture,DateTimeStyles.RoundtripKind);
                double age=(phaseUtc-utc.ToUniversalTime()).TotalSeconds;
                var metrics=(Dictionary<string,object>)raw["Metrics"];var selected=new Dictionary<string,object>();
                foreach(string key in new[]{"paging.total_faults_per_second","paging.read_operations_per_second","paging.input_pages_per_second","disk.read_bytes_per_second","disk.write_bytes_per_second","cpu.system_percent"})
                    if(metrics.ContainsKey(key))selected[key]=metrics[key];
                return new {Status=age<0?"future_context":age>90?"stale":"cached",SourceUtc=utc.ToUniversalTime().ToString("o"),AgeSeconds=age,Metrics=selected};
            } catch {return new {Status="unavailable",Reason="diagnostic_context_missing_or_invalid"};}
        }
        static double? Delta(ObservationSnapshot now,ObservationSnapshot before,string key) {
            ulong? a,b;
            if(now==null||before==null||!now.Bytes.TryGetValue(key,out a)||!before.Bytes.TryGetValue(key,out b)||!a.HasValue||!b.HasValue)return null;
            return a.Value>=b.Value?(double)(a.Value-b.Value):-(double)(b.Value-a.Value);
        }
        void Emit(Job job,string phase,double offset,ObservationSnapshot sample,string reason=null) {
            double now=clock.Seconds;DateTime utc=clock.UtcNow;
            if(sample!=null){now=sample.Seconds;utc=DateTime.Parse(sample.Utc,CultureInfo.InvariantCulture,DateTimeStyles.RoundtripKind).ToUniversalTime();}
            double elapsed=now-job.Receipt.After.Seconds;
            var record=new ObservationRecord {AttemptId=job.Receipt.AttemptId,Identity=job.Identity,Phase=phase,PlannedOffsetSeconds=offset,
                Utc=utc.ToString("o"),ActualElapsedSeconds=elapsed,LatenessSeconds=Math.Max(0,elapsed-offset),Snapshot=sample,
                Status=sample==null?"unavailable":sample.Status,Reason=reason,DiagnosticContext=Context(utc)};
            record.Changes["target.working_set_delta_from_before_bytes"]=Delta(sample,job.Receipt.Before,"target.working_set_bytes");
            record.Changes["target.working_set_rebound_from_after_bytes"]=phase=="before"?null:Delta(sample,job.Receipt.After,"target.working_set_bytes");
            record.Changes["physical.available_delta_from_before_bytes"]=Delta(sample,job.Receipt.Before,"physical.available_bytes");
            record.Changes["commit.delta_from_before_bytes"]=Delta(sample,job.Receipt.Before,"commit.used_bytes");
            foreach(string key in new[]{"target.logical_read_bytes_total","target.logical_write_bytes_total","self.logical_read_bytes_total","self.logical_write_bytes_total"}) {
                double? change=Delta(sample,job.Receipt.After,key);
                record.Changes[key+"_since_after"]=change.HasValue&&change>=0?change:null;
            }
            record.Changes["self.cpu_seconds_since_after"]=sample!=null&&sample.SelfCpuSeconds.HasValue&&job.Receipt.After.SelfCpuSeconds.HasValue&&sample.SelfCpuSeconds>=job.Receipt.After.SelfCpuSeconds?
                sample.SelfCpuSeconds-job.Receipt.After.SelfCpuSeconds:null;
            try {write(record);}catch{WriteFailures++;}
        }
        // Only called on one worker thread. Enqueue holds the lock for bounded metadata work only.
        public void Tick() {
            Job[] snapshot;lock(gate){if(stopped)return;snapshot=jobs.ToArray();}
            foreach(var job in snapshot) {
                if(!job.BaselinesWritten){Emit(job,"before",0,job.Receipt.Before);Emit(job,"after",0,job.Receipt.After);job.BaselinesWritten=true;}
                while(job.Stage<2) {
                    double offset=job.Stage==0?30:120;double elapsed=clock.Seconds-job.Receipt.After.Seconds;
                    if(elapsed<offset)break;
                    ObservationSnapshot sample=null;string reason=null;
                    if(elapsed-offset>DeadlineToleranceSeconds)reason="missed_deadline";
                    else {
                        try {sample=source.Read(job.Identity);if(!ValidSnapshot(sample)||sample.Seconds<job.Receipt.After.Seconds+offset||sample.Seconds>clock.Seconds){sample=null;reason="invalid_observation";}}
                        catch {reason="target_exited_identity_mismatch_or_api_unavailable";}
                        if(clock.Seconds-job.Receipt.After.Seconds-offset>DeadlineToleranceSeconds){sample=null;reason="collection_finished_late";}
                    }
                    Emit(job,job.Stage==0?"30s":"120s",offset,sample,reason);job.Stage++;
                }
                if(job.Stage==2)lock(gate)jobs.Remove(job);
            }
        }
        public int NextWaitMilliseconds {
            get {lock(gate){double wait=3600;foreach(var job in jobs){if(!job.BaselinesWritten)return 0;wait=Math.Min(wait,job.Receipt.After.Seconds+(job.Stage==0?30:120)-clock.Seconds);}return (int)Math.Max(0,Math.Min(3600000,Math.Ceiling(wait*1000)));}}
        }
        public void Stop() {lock(gate)stopped=true;}
        public void CancelPending() {
            Job[] snapshot;lock(gate){stopped=true;snapshot=jobs.ToArray();jobs.Clear();}
            foreach(var job in snapshot){if(!job.BaselinesWritten){Emit(job,"before",0,job.Receipt.Before);Emit(job,"after",0,job.Receipt.After);}
                for(int i=job.Stage;i<2;i++)Emit(job,i==0?"30s":"120s",i==0?30:120,null,"observer_stopped");}
        }
    }
    public sealed class PostTrimEngine : IDisposable {
        readonly object gate=new object();readonly AutoResetEvent wake=new AutoResetEvent(false);readonly Thread worker;
        readonly PostTrimScheduler scheduler;readonly string directory;bool disposed,exited;string error,latest;long writes;
        public string LastError {get{lock(gate)return error;}}
        public string LatestJson {get{lock(gate)return latest;}}
        public int Pending {get{return scheduler.Pending;}}
        public bool WorkerAlive {get{return worker.IsAlive;}}
        public long LogWrites {get{return Interlocked.Read(ref writes);}}
        public PostTrimEngine(string directory,Func<string> context=null) : this(directory,new ObservationClock(),new NativeTargetObservationSource(),context) {}
        public PostTrimEngine(string directory,IObservationClock clock,ITargetObservationSource source,Func<string> context) {
            this.directory=directory;scheduler=new PostTrimScheduler(clock,source,Write,context);
            worker=new Thread(Run);worker.IsBackground=true;worker.Name="RAM NEKO post-trim observation";worker.Start();
        }
        public string Enqueue(string json) {lock(gate){if(disposed)return "stopped";string result=scheduler.Enqueue(json);if(result=="accepted")wake.Set();return result;}}
        public static void AppendBounded(string path,string json,long limit=5242880) {
            Directory.CreateDirectory(Path.GetDirectoryName(path));var encoding=new System.Text.UTF8Encoding(false);string line=json+Environment.NewLine;
            long bytes=encoding.GetByteCount(line);if(bytes>limit)throw new ArgumentException("Observation record exceeds log capacity");
            if(File.Exists(path)&&new FileInfo(path).Length+bytes>limit){if(File.Exists(path+".1"))File.Delete(path+".1");File.Move(path,path+".1");}
            File.AppendAllText(path,line,encoding);
        }
        void Write(ObservationRecord record) {
            try {string json=new JavaScriptSerializer().Serialize(record);lock(gate)latest=json;
                AppendBounded(Path.Combine(directory,"post-trim.jsonl"),json);Interlocked.Increment(ref writes);}
            catch(Exception ex){lock(gate)error="post_trim_log_io: "+ex.GetType().Name;throw;}
        }
        void Run() {
            try {while(true){lock(gate)if(disposed)break;scheduler.Tick();wake.WaitOne(scheduler.NextWaitMilliseconds);}}
            catch(Exception ex){lock(gate)error="post_trim_worker: "+ex.GetType().Name;}
            finally {scheduler.CancelPending();lock(gate){exited=true;if(disposed)wake.Dispose();}}
        }
        public void Dispose(){lock(gate){if(disposed)return;disposed=true;scheduler.Stop();if(exited)wake.Dispose();else wake.Set();}}
        public bool WaitForStop(int milliseconds){return worker.Join(milliseconds);}
    }
}
