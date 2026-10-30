using Ryujinx.Cpu.LightningJit.State;
using System;
using System.Collections.Generic;
using System.Runtime.ExceptionServices;
using System.Threading;

namespace Ryujinx.Cpu.LightningJit
{
    // Shares only concurrent compilation, never executable pointers or completed
    // translations. Every caller still maps code on its own thread/frame pointer.
    sealed class CompilationCoordinator : IDisposable
    {
        internal delegate CompiledFunction CompileFunction(ulong address, ExecutionMode mode);

        private sealed class Entry
        {
            public readonly long Generation;
            public readonly int OwnerThreadId;
            public int Waiters;
            public bool Completed;
            public byte[] Code;
            public int GuestCodeLength;
            public ExceptionDispatchInfo Error;

            public Entry(long generation)
            {
                Generation = generation;
                OwnerThreadId = Environment.CurrentManagedThreadId;
            }
        }

        // Monitor.Wait releases this gate. Guest memory reads, compilation and
        // native mapping never run under it, including reentrant compilation.
        private readonly object _gate = new();
        private readonly Dictionary<(ulong Address, ExecutionMode Mode), Entry> _inFlight = new();
        private long _generation;
        private bool _disposed;
        private long _compiled, _merged, _retries, _copies, _reentrant;

        public CompiledFunction Compile(ulong address, ExecutionMode mode, CompileFunction compile)
        {
            var key = (address, mode);
            while (true)
            {
                Entry entry;
                long generation;
                lock (_gate)
                {
                    ObjectDisposedException.ThrowIf(_disposed, this);
                    generation = _generation;
                    if (_inFlight.TryGetValue(key, out entry))
                    {
                        if (entry.OwnerThreadId == Environment.CurrentManagedThreadId)
                        {
                            // A compiler may synchronously request the same block.
                            // Bypass sharing instead of waiting on its own result.
                            _reentrant++;
                            entry = null;
                        }
                        else
                        {
                            entry.Waiters++;
                            _merged++;
                            while (!entry.Completed && entry.Generation == _generation && !_disposed)
                            {
                                Monitor.Wait(_gate);
                            }

                            ObjectDisposedException.ThrowIf(_disposed, this);
                            if (entry.Generation != _generation)
                            {
                                _retries++;
                                continue;
                            }

                            entry.Error?.Throw();
                            return new CompiledFunction(entry.Code, entry.GuestCodeLength);
                        }
                    }
                    else
                    {
                        entry = new Entry(generation);
                        _inFlight.Add(key, entry);
                    }

                    _compiled++;
                }

                try
                {
                    CompiledFunction result = compile(address, mode);
                    lock (_gate)
                    {
                        ObjectDisposedException.ThrowIf(_disposed, this);
                        if (generation != _generation)
                        {
                            _retries++;
                            continue;
                        }

                        if (entry != null)
                        {
                            // CompiledFunction is a ref struct. Only real waiters
                            // need an owned snapshot; uncontended calls add no copy.
                            if (entry.Waiters != 0)
                            {
                                entry.Code = result.Code.ToArray();
                                entry.GuestCodeLength = result.GuestCodeLength;
                                _copies++;
                            }
                            entry.Completed = true;
                            _inFlight.Remove(key);
                            Monitor.PulseAll(_gate);
                        }

                        return result;
                    }
                }
                catch (Exception error)
                {
                    lock (_gate)
                    {
                        if (entry != null)
                        {
                            entry.Error = ExceptionDispatchInfo.Capture(error);
                            entry.Completed = true;
                            if (_inFlight.TryGetValue(key, out Entry current) && ReferenceEquals(current, entry))
                            {
                                _inFlight.Remove(key);
                            }
                            Monitor.PulseAll(_gate);
                        }

                        // An invalidation may have interrupted a memory read.
                        // Do not propagate or share that old-generation result.
                        if (!_disposed && generation != _generation)
                        {
                            _retries++;
                            continue;
                        }
                    }
                    throw;
                }
            }
        }

        public void Invalidate()
        {
            lock (_gate)
            {
                _generation++;
                _inFlight.Clear();
                Monitor.PulseAll(_gate);
            }
        }

        public (long Compiled, long Merged, long Retries, long Copies, long Reentrant) GetStatistics()
        {
            lock (_gate) { return (_compiled, _merged, _retries, _copies, _reentrant); }
        }

        public void Dispose()
        {
            lock (_gate)
            {
                _disposed = true;
                _generation++;
                _inFlight.Clear();
                Monitor.PulseAll(_gate);
            }
        }
    }
}
