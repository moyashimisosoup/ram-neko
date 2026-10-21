namespace RamNeko.Diagnostics.Testing {
    public sealed class Clock : IDiagnosticClock {
        public double Now; public System.DateTime Utc=System.DateTime.SpecifyKind(new System.DateTime(2026,1,1),System.DateTimeKind.Utc);
        public System.DateTime UtcNow {get{return Utc.AddSeconds(Now);}} public double Seconds {get{return Now;}}
    }
    public sealed class Source : IDiagnosticSource {
        public RawSnapshot Value=new RawSnapshot();public bool Throw,Disposed;
        public RawSnapshot Read(){if(Throw)throw new System.UnauthorizedAccessException();return Value;}
        public void Dispose(){Disposed=true;}
        public System.Func<IDiagnosticSource> Factory(){return delegate{return this;};}
    }
}
