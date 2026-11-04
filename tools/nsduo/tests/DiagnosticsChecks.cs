using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Threading.Tasks;
using Ryujinx.Common;
using Ryujinx.Common.Logging;

static class DiagnosticsChecks
{
    static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
    static long T(double seconds) => (long)(seconds * Stopwatch.Frequency);
    static void Main()
    {
        // The core is loaded by a Swift executable, so iOS has no managed entry assembly.
        Assembly entry = Assembly.GetEntryAssembly();
        try
        {
            Assembly.SetEntryAssembly(null);
            Check(Assembly.GetEntryAssembly() == null, "native-host fixture has no managed entry assembly");
            Check(!string.IsNullOrWhiteSpace(ReleaseInformation.Version), "native-host version must remain readable");
        }
        finally { Assembly.SetEntryAssembly(entry); }

        // Optional diagnostic setup must not abort game startup on invalid paths.
        GameDiagnostics.Start("invalid\0path", "game", "settings");
        GameDiagnostics.Frame();
        GameDiagnostics.End();

        var tracker = new DiagnosticFrameTracker();
        tracker.Reset(T(1));
        Check(!tracker.Read(T(10)).IsStalled && tracker.Read(T(32)).IsStalled, "loading timeout");
        Check(tracker.Frame(T(33)), "first frame");
        Check(tracker.Read(T(33)).MaxGapMs == 0, "initial load is not a long render frame");
        tracker.Frame(T(33.5));
        Check(tracker.Read(T(34)).LongFrames == 1 && tracker.Read(T(36)).IsStalled, "long frame/stall");
        tracker.Pause(true, T(36));
        Check(!tracker.Read(T(600)).IsStalled, "paused session must not trigger a stall");
        tracker.Pause(false, T(600));
        tracker.Frame(T(600.01));
        Check(tracker.Read(T(600.01)).MaxGapMs < 501, "resume must not include pause time");
        string cleaned = DiagnosticSession.Clean("fail /private/container/game.nsp token=abcd\npassword=secret");
        Check(!cleaned.Contains("abcd") && !cleaned.Contains("container") && !cleaned.Contains("=secret") && !cleaned.Contains('\n'), "redaction");

        string root = Path.Combine(Path.GetTempPath(), "nsduo-diagnostics-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        try
        {
            bool metadataAttempted = false;
            GameDiagnostics.Start(root, "game", () =>
            {
                metadataAttempted = true;
                throw new InvalidOperationException("synthetic metadata failure");
            });
            Check(metadataAttempted, "metadata evaluated within the optional diagnostic boundary");
            GameDiagnostics.Frame();
            GameDiagnostics.End();

            Assembly.SetEntryAssembly(null);
            try
            {
                GameDiagnostics.Start(root, "Native host", () => "core=" + ReleaseInformation.Version);
                GameDiagnostics.End();
                Check(Directory.GetFiles(root, "info.txt", SearchOption.AllDirectories)
                    .Any(p => File.ReadAllText(p).Contains("Native host")), "native-host recording recovers after failed initialization");
            }
            finally { Assembly.SetEntryAssembly(entry); }

            var failureSession = new DiagnosticSession(root, "Failure fixture", "resolution=1");
            Parallel.For(0, 4000, i => failureSession.Record("burst", "queued event " + i));
            try
            {
                throw new InvalidOperationException("synthetic /private/container/game.nsp token=abcd");
            }
            catch (Exception error)
            {
                failureSession.Exception("managed_exception", error.ToString(), terminating: true);
            }
            // Read before Dispose: a terminating exception must not depend on
            // draining the asynchronous sampling queue.
            string fatal = File.ReadAllText(Path.Combine(failureSession.DirectoryPath, "fatal.log"));
            Check(fatal.Contains(nameof(InvalidOperationException)) && fatal.Contains(nameof(Main)), "exception type and stack are retained immediately");
            Check(!fatal.Contains("abcd") && !fatal.Contains("/private/container"), "exception details are redacted");
            failureSession.OnLog(null, new LogEventArgs(LogLevel.Error, TimeSpan.Zero, "CPU", "Cpu synthetic failure"));
            Check(File.ReadAllText(Path.Combine(failureSession.DirectoryPath, "exceptions.log")).Contains("Cpu synthetic failure"), "non-GPU errors are retained immediately");
            for (int i = 0; i < 80; i++) failureSession.Exception("burst", new string('x', 8000), false);
            Check(new FileInfo(Path.Combine(failureSession.DirectoryPath, "exceptions.log")).Length <= DiagnosticSession.ExceptionLimit, "exception bursts are bounded");
            Check(File.Exists(Path.Combine(failureSession.DirectoryPath, "problem")), "problem marker is persisted before disposal");
            failureSession.Dispose();

            var session = new DiagnosticSession(root, "Test game", "resolution=1", 2048);
            session.Problem("test marker");
            session.Title("Test game named", "1.0");
            Parallel.For(0, 4000, i => session.Record("load", "test " + i + new string('x', 120)));
            session.Dispose();
            session.Record("late", "must be harmless");
            session.Dispose();
            Check(File.Exists(Path.Combine(session.DirectoryPath, "problem")), "problem must survive shutdown");
            Check(!File.Exists(Path.Combine(session.DirectoryPath, "running")), "clean shutdown marker");
            Check(File.ReadAllText(Path.Combine(session.DirectoryPath, "info.txt")).Contains("Test game named 1.0"), "metadata retention and title update");
            var logs = Directory.GetFiles(session.DirectoryPath, "*.log");
            Check(logs.Length <= 2 && logs.All(p => new FileInfo(p).Length <= 2048), "bounded rotating logs");
            Check(File.ReadAllText(Path.Combine(session.DirectoryPath, "current.log")).Contains("\tend\t"), "drained completion");
            for (int i = 0; i < 22; i++)
            {
                string dir = Path.Combine(root, $"synthetic-{i:00}"); Directory.CreateDirectory(dir);
                File.WriteAllText(Path.Combine(dir, "info.txt"), "synthetic");
                if (i < 12) File.WriteAllText(Path.Combine(dir, "problem"), "issue");
            }
            string stale = Path.Combine(root, "zzz-interrupted"); Directory.CreateDirectory(stale);
            File.WriteAllText(Path.Combine(stale, "info.txt"), "game");
            File.WriteAllText(Path.Combine(stale, "running"), "unfinished");
            DiagnosticSession.RecoverAndTrim(root);
            Check(File.ReadAllText(Path.Combine(stale, "problem")).Contains("could be"), "interrupted session must not be mislabeled a confirmed crash");
            var dirs = Directory.GetDirectories(root);
            Check(dirs.Count(d => File.Exists(Path.Combine(d, "problem"))) <= DiagnosticSession.ProblemLimit, "issue retention");
            Check(dirs.Count(d => !File.Exists(Path.Combine(d, "problem"))) < DiagnosticSession.NormalLimit, "normal retention reserves current session");
            string blocked = Path.Combine(root, "not-a-directory"); File.WriteAllText(blocked, "x");
            GameDiagnostics.Start(blocked, "game", ""); GameDiagnostics.Frame(); GameDiagnostics.End();
            Console.WriteLine("PASS diagnostics: native-host version, metadata/setup failure isolation, watchdog, pause/resume, bounded rotation/queue, retained issues, interrupted sessions, privacy and IO failure");
        }
        finally { Directory.Delete(root, true); }
    }
}
