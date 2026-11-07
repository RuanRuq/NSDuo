using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace Ryujinx.Common.Logging
{
    // Diagnostic IO runs on its own bounded queue. Rendering only updates counters.
    public static class GameDiagnostics
    {
        private static DiagnosticSession _session;
        private static string _exceptionRoot;
        private static int _exceptionHandlersInstalled;

        public static void InstallExceptionHandlers(string root)
        {
            Volatile.Write(ref _exceptionRoot, root);
            if (Interlocked.Exchange(ref _exceptionHandlersInstalled, 1) != 0) return;
            AppDomain.CurrentDomain.UnhandledException += (_, args) =>
            {
                try { RecordException("unhandled_managed_exception", args.ExceptionObject?.ToString() ?? "Unknown exception", args.IsTerminating); }
                catch (Exception) { }
            };
            TaskScheduler.UnobservedTaskException += (_, args) =>
            {
                // Record only: do not change the runtime's exception policy.
                Exception("unobserved_task_exception", args.Exception);
            };
        }

        public static void Exception(string source, Exception error, bool terminating = false)
        {
            try { RecordException(source, error?.ToString() ?? "Unknown exception", terminating); }
            catch (Exception) { /* Reporting must never replace the original failure. */ }
        }

        private static void RecordException(string source, string details, bool terminating)
        {
            try
            {
                var session = Volatile.Read(ref _session);
                if (session != null && session.Exception(source, details, terminating)) return;
                string root = Volatile.Read(ref _exceptionRoot);
                if (!string.IsNullOrEmpty(root)) DiagnosticSession.StandaloneException(root, source, details, terminating);
            }
            catch (Exception) { /* Best effort, including a full disk or shutdown. */ }
        }

        public static void Start(string root, string title, string settings)
            => Start(root, title, () => settings);

        public static void Start(string root, string title, Func<string> settings)
        {
            End();
            try
            {
                InstallExceptionHandlers(root);
                // Evaluate optional metadata inside the same failure boundary as IO.
                var session = new DiagnosticSession(root, title, settings());
                Volatile.Write(ref _session, session);
                Logger.Updated += session.OnLog;
            }
            catch (Exception)
            {
                // Diagnostic setup is best effort. Metadata, platform APIs or IO
                // must never prevent the emulator from starting a game.
            }
        }

        public static void End()
        {
            var session = Interlocked.Exchange(ref _session, null);
            if (session == null) return;
            Logger.Updated -= session.OnLog;
            session.Dispose();
        }

        public static void Frame() => Volatile.Read(ref _session)?.Frame();
        public static void Pause(bool paused) => Volatile.Read(ref _session)?.Pause(paused);
        public static void Phase(string phase) => Volatile.Read(ref _session)?.Phase(phase);
        public static void Event(string message) => Volatile.Read(ref _session)?.Record("event", message);
        public static void Problem(string message) => Volatile.Read(ref _session)?.Problem(message);
        public static void Statistics(double fps, double frameMs, double fifo) => Volatile.Read(ref _session)?.Statistics(fps, frameMs, fifo);
        public static void Title(string title, string version) => Volatile.Read(ref _session)?.Title(title, version);
        public static GraphicsTimingScope MeasureGraphics(GraphicsTimingKind kind)
            => Volatile.Read(ref _session)?.MeasureGraphics(kind) ?? default;
    }

    internal sealed class DiagnosticSession : IDisposable
    {
        internal const int SegmentLimit = 2 * 1024 * 1024;
        internal const int NormalLimit = 5;
        internal const int ProblemLimit = 10;
        internal const int ExceptionLimit = 128 * 1024;
        private const int ExceptionDetailsLimit = 16 * 1024;
        private readonly string _directory;
        private readonly int _segmentLimit;
        private readonly BlockingCollection<string> _queue = new(256);
        private readonly Thread _writer;
        private readonly Stopwatch _clock = Stopwatch.StartNew();
        private readonly DiagnosticFrameTracker _frames = new();
        private readonly DiagnosticTimingCounter[] _graphicsTimings = Enumerable.Range(0, (int)GraphicsTimingKind.Count)
            .Select(_ => new DiagnosticTimingCounter()).ToArray();
        private readonly long[] _lastGraphicsTimingCalls = new long[(int)GraphicsTimingKind.Count];
        private FileStream _file;
        private int _closed;
        private int _problem;
        private int _dropped;
        private int _stop;
        private string _phase = "loading_game";
        private double _fps, _frameMs, _fifo;
        private readonly string _settings;
        private readonly string _started = DateTime.UtcNow.ToString("O");
        private string _title;
        private int _metadataChanged;
        private readonly object _exceptionLock = new();

        internal DiagnosticSession(string root, string title, string settings, int segmentLimit = SegmentLimit)
        {
            _segmentLimit = segmentLimit;
            _title = Clean(title);
            _settings = Clean(settings);
            Directory.CreateDirectory(root);
            RecoverAndTrim(root);
            _directory = Path.Combine(root, $"{DateTime.UtcNow:yyyyMMdd-HHmmss-fff}-{Guid.NewGuid():N}");
            Directory.CreateDirectory(_directory);
            // Metadata is retained even when verbose output has rotated out.
            WriteInfo();
            File.WriteAllText(Path.Combine(_directory, "running"), "unfinished");
            _frames.Reset(Stopwatch.GetTimestamp());
            Record("start", "Local diagnostics; timestamps are UTC. No-frame intervals are observations, not a diagnosis.");
            _writer = new Thread(WriteLoop) { IsBackground = true, Name = "NSDuo.Diagnostics", Priority = ThreadPriority.BelowNormal };
            _writer.Start();
        }

        internal string DirectoryPath => _directory;

        internal GraphicsTimingScope MeasureGraphics(GraphicsTimingKind kind)
        {
            if (Volatile.Read(ref _closed) != 0 || (uint)kind >= (uint)_graphicsTimings.Length) return default;
            return new GraphicsTimingScope(_graphicsTimings[(int)kind]);
        }

        private void WriteGraphicsTimings(bool paused)
        {
            for (int i = 0; i < _graphicsTimings.Length; i++)
            {
                var timing = _graphicsTimings[i].Read();
                if (timing.Active == 0 && timing.Calls == _lastGraphicsTimingCalls[i]) continue;
                _lastGraphicsTimingCalls[i] = timing.Calls;
                double totalMs = timing.TotalTicks * 1000.0 / Stopwatch.Frequency;
                WriteEvent("graphics_timing", $"kind={(GraphicsTimingKind)i}; cumulative=true; phase={_phase}; paused={paused}; calls={timing.Calls}; total_ms={totalMs:F3}; avg_ms={(timing.Calls == 0 ? 0 : totalMs / timing.Calls):F3}; max_ms={timing.MaxTicks * 1000.0 / Stopwatch.Frequency:F3}; over_1ms={timing.Over1Ms}; over_16ms={timing.Over16Ms}; active={timing.Active}");
            }
        }

        private void WriteInfo()
        {
            string temporary = Path.Combine(_directory, "info.tmp");
            File.WriteAllText(temporary, Volatile.Read(ref _title) + "\n" + _started + "\n" + _settings + "\n", Encoding.UTF8);
            File.Move(temporary, Path.Combine(_directory, "info.txt"), overwrite: true);
        }

        internal void Title(string title, string version)
        {
            if (string.IsNullOrWhiteSpace(title)) return;
            Volatile.Write(ref _title, Clean(title + " " + version));
            Interlocked.Exchange(ref _metadataChanged, 1);
            Record("game", title + " " + version);
        }

        internal static string Clean(string value)
        {
            value ??= "";
            if (value.Length > 2048) value = value[..2048];
            value = value.Replace('\r', ' ').Replace('\n', ' ').Replace('\t', ' ');
            // Do not retain container/source paths or accidentally formatted credentials.
            value = Regex.Replace(value, @"/(?:[^\s\""']+)", "[path]");
            return Regex.Replace(value, @"(?i)(password|token|secret|private_key|prod_key|pairing)\s*[:=]\s*\S+", "$1=[redacted]");
        }

        internal void Record(string kind, string message)
        {
            if (Volatile.Read(ref _closed) != 0) return;
            if (_queue.Count >= 256) { Interlocked.Increment(ref _dropped); return; }
            string line = $"{DateTime.UtcNow:O}\t{_clock.Elapsed.TotalSeconds:F3}\t{kind}\t{Clean(message)}";
            try { if (!_queue.TryAdd(line)) Interlocked.Increment(ref _dropped); }
            catch (InvalidOperationException) { }
        }

        internal void Problem(string message)
        {
            Interlocked.Exchange(ref _problem, 1);
            Record("problem", message);
        }

        internal bool Exception(string source, string details, bool terminating)
        {
            if (Volatile.Read(ref _closed) != 0) return false;
            Interlocked.Exchange(ref _problem, 1);
            Record("exception", $"source={source}; terminating={terminating}; details in exception log");
            // Fatal output uses a separate file, so it never waits for the
            // sampling writer or an error burst on another thread.
            if (terminating)
            {
                WriteException(_directory, "fatal.log", source, details, true, Volatile.Read(ref _phase));
            }
            else
            {
                lock (_exceptionLock)
                    WriteException(_directory, "exceptions.log", source, details, false, Volatile.Read(ref _phase));
            }
            return true;
        }

        internal static void StandaloneException(string root, string source, string details, bool terminating)
        {
            string directory = Path.Combine(root, $"{DateTime.UtcNow:yyyyMMdd-HHmmss-fff}-{Guid.NewGuid():N}");
            Directory.CreateDirectory(directory);
            WriteException(directory, "fatal.log", source, details, terminating, "outside_game_session");
            File.WriteAllText(Path.Combine(directory, "info.txt"), $"App 核心异常\n{DateTime.UtcNow:O}\ncore={ReleaseInformation.Version}\n", Encoding.UTF8);
            // A task may fail without any game running. Bound those records
            // too, while leaving any concurrently started game untouched.
            var completed = new DirectoryInfo(root).GetDirectories()
                .Where(d => !d.Attributes.HasFlag(FileAttributes.ReparsePoint)
                    && File.Exists(Path.Combine(d.FullName, "info.txt"))
                    && File.Exists(Path.Combine(d.FullName, "problem"))
                    && !File.Exists(Path.Combine(d.FullName, "running")))
                .OrderByDescending(d => d.Name).ToArray();
            foreach (var old in completed.Skip(ProblemLimit))
            {
                try { old.Delete(recursive: true); }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
            }
        }

        private static void WriteException(string directory, string filename, string source, string details, bool terminating, string phase)
        {
            try
            {
                details ??= "Unknown exception";
                bool truncated = details.Length > ExceptionDetailsLimit;
                if (truncated) details = details[..ExceptionDetailsLimit];
                string cleaned = string.Join('\n', details.Replace("\r\n", "\n").Split('\n').Select(Clean));
                string message = $"{DateTime.UtcNow:O}\texception\tsource={Clean(source)}; terminating={terminating}; phase={Clean(phase)}; thread={Environment.CurrentManagedThreadId} ({Clean(Thread.CurrentThread.Name)})\n{cleaned}\n";
                if (truncated) message += "[exception details truncated]\n";
                // Preserve the first errors when a core repeatedly reports the
                // same failure; fatal.log remains available for the final one.
                using var file = new FileStream(Path.Combine(directory, filename),
                    terminating ? FileMode.Create : FileMode.Append, FileAccess.Write,
                    terminating ? FileShare.Read : FileShare.ReadWrite);
                byte[] bytes = Encoding.UTF8.GetBytes(message);
                if (file.Length + bytes.Length <= ExceptionLimit)
                {
                    file.Write(bytes);
                    file.Flush(flushToDisk: true);
                }
                File.WriteAllText(Path.Combine(directory, "problem"), "Exception/error recorded; inspect the exception log.");
            }
            catch (Exception) { /* Optional diagnostics must not throw from a failing thread. */ }
        }

        internal void OnLog(object sender, LogEventArgs args)
        {
            // Capture all core Error classes, including CPU/HLE/loader failures.
            // Keep ordinary verbose output limited to GPU events as before.
            if (args.Level == LogLevel.Error)
            {
                try
                {
                    string details = args.Message + (args.Data == null ? "" : "\n" + args.Data);
                    Exception("core_error", details, terminating: false);
                }
                catch (Exception) { }
                return;
            }
            if (args.Message?.StartsWith("Gpu ", StringComparison.Ordinal) != true) return;
            if (args.Level is LogLevel.Debug or LogLevel.Trace or LogLevel.Stub) return;
            Record("gpu_" + args.Level, args.Message);
        }

        internal void Frame()
        {
            if (_frames.Frame(Stopwatch.GetTimestamp()))
            {
                Volatile.Write(ref _phase, "playing");
                Record("first_frame", "First presented frame");
            }
        }

        internal void Pause(bool paused)
        {
            _frames.Pause(paused, Stopwatch.GetTimestamp());
            Record(paused ? "paused" : "resumed", "");
        }

        internal void Phase(string phase)
        {
            Volatile.Write(ref _phase, phase);
            if (phase == "stopping") Volatile.Write(ref _stop, 1);
            Record("phase", phase);
        }

        internal void Statistics(double fps, double frameMs, double fifo)
        {
            Volatile.Write(ref _fps, fps);
            Volatile.Write(ref _frameMs, frameMs);
            Volatile.Write(ref _fifo, fifo);
        }

        private void WriteLoop()
        {
            long nextSample = 0;
            long nextHeartbeat = 0;
            long lastStallLog = -10_000;
            bool stalled = false;
            bool marked = false;
            try
            {
                OpenFile();
                while (!_queue.IsCompleted)
                {
                    if (_queue.TryTake(out string line, 1000)) WriteLine(line);
                    // Sample at most once per second, even during bursts of GPU messages.
                    long now = _clock.ElapsedMilliseconds;
                    if (now < nextSample) continue;
                    nextSample = now + 1000;
                    if (Interlocked.Exchange(ref _metadataChanged, 0) != 0) WriteInfo();
                    var sample = _frames.Read(Stopwatch.GetTimestamp());
                    if (sample.MaxGapMs >= 2000) Interlocked.Exchange(ref _problem, 1);
                    bool noFrame = Volatile.Read(ref _stop) == 0 && sample.IsStalled;
                    if (noFrame && now - lastStallLog >= 10_000)
                    {
                        Interlocked.Exchange(ref _problem, 1);
                        WriteEvent("no_frame", $"phase={_phase}; gap_ms={sample.GapMs:F0}; frames={sample.Frames}; not necessarily a hang");
                        lastStallLog = now;
                    }
                    if (stalled && !noFrame && !sample.Paused && Volatile.Read(ref _stop) == 0)
                        WriteEvent("recovered", "Frames resumed");
                    stalled = noFrame;
                    if (now >= nextHeartbeat)
                    {
                        nextHeartbeat = now + 5000;
                        WriteEvent("sample", $"phase={_phase}; paused={sample.Paused}; frames={sample.Frames}; fps={Volatile.Read(ref _fps):F2}; frame_ms={Volatile.Read(ref _frameMs):F2}; fifo_percent={Volatile.Read(ref _fifo):F2}; gap_ms={sample.GapMs:F0}; max_gap_ms={sample.MaxGapMs:F0}; long_frames={sample.LongFrames}; managed_mb={GC.GetTotalMemory(false) / 1048576}; dropped={Interlocked.Exchange(ref _dropped, 0)}");
                        WriteGraphicsTimings(sample.Paused);
                    }
                    if (!marked && Volatile.Read(ref _problem) != 0)
                    {
                        File.WriteAllText(Path.Combine(_directory, "problem"), "Issue observed or marked; inspect the log for context.");
                        marked = true;
                    }
                    _file.Flush();
                }
                if (Volatile.Read(ref _problem) != 0 && !marked)
                    File.WriteAllText(Path.Combine(_directory, "problem"), "Issue observed or marked.");
                if (Interlocked.Exchange(ref _metadataChanged, 0) != 0) WriteInfo();
                WriteGraphicsTimings(_frames.Read(Stopwatch.GetTimestamp()).Paused);
                WriteEvent("end", "Emulation owner returned normally to the app");
                _file.Flush();
                File.Delete(Path.Combine(_directory, "running"));
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                // Optional diagnostics must not crash or block emulation on a full disk.
                // Leave the running marker so incomplete logs can be recognized next time.
            }
            finally { _file?.Dispose(); }
        }

        private void WriteEvent(string kind, string message) => WriteLine($"{DateTime.UtcNow:O}\t{_clock.Elapsed.TotalSeconds:F3}\t{kind}\t{message}");
        private void OpenFile() => _file = new FileStream(Path.Combine(_directory, "current.log"), FileMode.Create, FileAccess.Write, FileShare.Read, 16 * 1024);
        private void WriteLine(string line)
        {
            byte[] bytes = Encoding.UTF8.GetBytes(line + "\n");
            if (_file.Length + bytes.Length > _segmentLimit)
            {
                _file.Dispose();
                File.Move(Path.Combine(_directory, "current.log"), Path.Combine(_directory, "previous.log"), overwrite: true);
                OpenFile();
            }
            _file.Write(bytes);
        }

        internal static void RecoverAndTrim(string root, bool reserveNewSession = true)
        {
            // Called only before starting a session, when no other writer belongs to this app.
            var folders = new DirectoryInfo(root).GetDirectories()
                .Where(d => !d.Attributes.HasFlag(FileAttributes.ReparsePoint) && File.Exists(Path.Combine(d.FullName, "info.txt")))
                .OrderByDescending(d => d.Name).ToArray();
            int normal = 0, problems = 0;
            foreach (var folder in folders)
            {
                string path = folder.FullName;
                try
                {
                    if (File.Exists(Path.Combine(path, "running")))
                        File.WriteAllText(Path.Combine(path, "problem"), "Previous session did not finish; could be a crash, forced quit or system termination.");
                    bool issue = File.Exists(Path.Combine(path, "problem"));
                    if (issue ? ++problems > ProblemLimit : ++normal > NormalLimit - (reserveNewSession ? 1 : 0))
                        folder.Delete(recursive: true);
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
            }
        }

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _closed, 1) != 0) return;
            _queue.CompleteAdding();
            _writer.Join();
            try { RecoverAndTrim(Path.GetDirectoryName(_directory), reserveNewSession: false); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
            // Keep the collection alive for producers that already took a session snapshot.
        }
    }

    internal sealed class DiagnosticFrameTracker
    {
        private long _lastFrame;
        private long _frames;
        private long _maxGap;
        private long _longFrames;
        private int _paused;

        internal void Reset(long now) => Interlocked.Exchange(ref _lastFrame, now);
        internal void Pause(bool paused, long now)
        {
            Volatile.Write(ref _paused, paused ? 1 : 0);
            Reset(now);
        }
        internal bool Frame(long now)
        {
            long previous = Interlocked.Exchange(ref _lastFrame, now);
            long count = Interlocked.Increment(ref _frames);
            long gap = now - previous;
            if (count > 1 && Volatile.Read(ref _paused) == 0 && gap >= Stopwatch.Frequency / 10)
            {
                Interlocked.Increment(ref _longFrames);
                long maximum;
                do { maximum = Volatile.Read(ref _maxGap); if (maximum >= gap) break; }
                while (Interlocked.CompareExchange(ref _maxGap, gap, maximum) != maximum);
            }
            return count == 1;
        }
        internal (long Frames, double GapMs, double MaxGapMs, long LongFrames, bool Paused, bool IsStalled) Read(long now)
        {
            long frames = Volatile.Read(ref _frames);
            double gap = Math.Max(0, now - Volatile.Read(ref _lastFrame)) * 1000.0 / Stopwatch.Frequency;
            bool paused = Volatile.Read(ref _paused) != 0;
            return (frames, gap, Volatile.Read(ref _maxGap) * 1000.0 / Stopwatch.Frequency, Volatile.Read(ref _longFrames), paused,
                !paused && gap >= (frames == 0 ? 30_000 : 2000));
        }
    }
}
