using System;

namespace Ryujinx.Common.Logging.Targets
{
    // Used by the single console-writer thread, after the diagnostic event has
    // already been delivered. Errors, warnings and structured data are retained.
    internal sealed class ConsoleRepeatFilter
    {
        private LogLevel _level;
        private string _message;
        private TimeSpan _windowStart;
        private int _suppressed;

        public bool Accept(LogEventArgs args, out int suppressed)
        {
            bool canCombine = args.Data == null && args.Level is LogLevel.Stub or LogLevel.Guest or LogLevel.Info;
            if (canCombine && args.Level == _level && args.Message == _message &&
                args.Time >= _windowStart && args.Time - _windowStart < TimeSpan.FromSeconds(1))
            {
                _suppressed++;
                suppressed = 0;
                return false;
            }

            suppressed = _suppressed;
            _suppressed = 0;
            _message = canCombine ? args.Message : null;
            _level = args.Level;
            _windowStart = args.Time;
            return true;
        }
    }
}
