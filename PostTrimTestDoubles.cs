using System;
using System.Collections.Generic;
using System.Web.Script.Serialization;
namespace RamNeko.Safety.Testing {
    public sealed class Clock : IObservationClock {
        public double Now=100;
        public DateTime UtcNow {get{return new DateTime(2026,1,1,0,0,0,DateTimeKind.Utc).AddSeconds(Now);}}
        public double Seconds {get{return Now;}}
    }
    public sealed class Source : ITargetObservationSource {
        public Clock Clock;public int Reads;public bool Throw,Invalid;public double AdvanceSeconds;public ulong? ReadBytesOverride;
        public Source(Clock clock){Clock=clock;}
        public ObservationSnapshot Read(CandidateIdentity identity) {
            Reads++;if(Throw)throw new InvalidOperationException("identity_mismatch");
            var result=Snapshot(Clock,180,800);Clock.Now+=AdvanceSeconds;
            if(ReadBytesOverride.HasValue)result.Bytes["target.logical_read_bytes_total"]=ReadBytesOverride;
            if(Invalid)result.Seconds=1;return result;
        }
        public static ObservationSnapshot Snapshot(Clock clock,ulong working,ulong available) {
            return new ObservationSnapshot {Utc=clock.UtcNow.ToString("o"),Seconds=clock.Now,Status="ok",SelfCpuSeconds=clock.Now,
                Bytes=new Dictionary<string,ulong?> {{"target.working_set_bytes",working},{"target.private_bytes",working},
                {"physical.available_bytes",available},{"commit.used_bytes",900},{"target.logical_read_bytes_total",(ulong)clock.Now*10},
                {"target.logical_write_bytes_total",(ulong)clock.Now*5},{"self.logical_read_bytes_total",(ulong)clock.Now}, {"self.logical_write_bytes_total",(ulong)clock.Now}}};
        }
    }
    public sealed class Harness {
        public readonly Clock Clock=new Clock();public readonly Source Source;
        public readonly List<ObservationRecord> Records=new List<ObservationRecord>();public readonly PostTrimScheduler Scheduler;
        public bool WriteFailure;
        public Harness(){Source=new Source(Clock);Scheduler=new PostTrimScheduler(Clock,Source,Write);}
        void Write(ObservationRecord record){if(WriteFailure)throw new System.IO.IOException();Records.Add(record);}
        public string Receipt(string attemptId=null) {
            var before=Source.Snapshot(Clock,300,500);before.Seconds-=1;
            return new JavaScriptSerializer().Serialize(new TrimReceipt {AttemptId=attemptId??Guid.NewGuid().ToString("N"),
                Identity=new CandidateIdentity(42,100,"chrome",1),Before=before,After=Source.Snapshot(Clock,100,700)});
        }
        public PostTrimScheduler WithContext(string json) {return new PostTrimScheduler(Clock,Source,Write,delegate{return json;});}
    }
    public sealed class ObservedNative : ITrimNative,ITrimObservation {
        public CandidateIdentity Identity=new CandidateIdentity(42,100,"chrome",1);
        public int Trims,Closes,Observations;public bool ObservationThrows;
        public IntPtr Open(int id){return new IntPtr(7);}
        public CandidateIdentity ReadIdentity(IntPtr handle){return Identity;}
        public void Empty(IntPtr handle){if(Observations!=1)throw new Exception("before_not_captured");Trims++;}
        public void Close(IntPtr handle){Closes++;}
        public ObservationSnapshot Observe(IntPtr handle){Observations++;if(ObservationThrows)throw new Exception("observer_failed");return Source.Snapshot(new Clock(),200,500);}
    }
}
