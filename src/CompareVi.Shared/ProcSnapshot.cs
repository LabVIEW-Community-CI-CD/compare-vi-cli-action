using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;

namespace CompareVi.Shared
{
    public sealed class ProcSnapshot
    {
        public IReadOnlyList<int> LabViewPids { get; }
        public IReadOnlyList<int> LvComparePids { get; }
        public IReadOnlyList<int> LabViewCliPids { get; }
        public IReadOnlyList<int> GcliPids { get; }

        public ProcSnapshot(IEnumerable<int>? lvPids, IEnumerable<int>? lvcPids)
            : this(lvPids, lvcPids, null, null)
        {
        }

        public ProcSnapshot(
            IEnumerable<int>? lvPids,
            IEnumerable<int>? lvcPids,
            IEnumerable<int>? labViewCliPids,
            IEnumerable<int>? gcliPids)
        {
            LabViewPids = Normalize(lvPids);
            LvComparePids = Normalize(lvcPids);
            LabViewCliPids = Normalize(labViewCliPids);
            GcliPids = Normalize(gcliPids);
        }

        private static IReadOnlyList<int> Normalize(IEnumerable<int>? pids)
        {
            return pids?.Distinct().OrderBy(x => x).ToArray() ?? Array.Empty<int>();
        }

        public static ProcSnapshot Capture()
        {
            IEnumerable<int> get(params string[] names)
            {
                var results = new HashSet<int>();
                foreach (var name in names)
                {
                    if (string.IsNullOrWhiteSpace(name))
                    {
                        continue;
                    }
                    try
                    {
                        foreach (var process in Process.GetProcessesByName(name))
                        {
                            results.Add(process.Id);
                        }
                    }
                    catch
                    {
                        // ignored
                    }
                }
                return results;
            }

            return new ProcSnapshot(
                get("LabVIEW"),
                get("LVCompare"),
                get("LabVIEWCLI", "labviewcli"),
                get("g-cli", "gcli"));
        }

        public IReadOnlyList<int> NewLabViewSince(ProcSnapshot before)
        {
            var set = new HashSet<int>(before.LabViewPids);
            return LabViewPids.Where(id => !set.Contains(id)).ToArray();
        }

        public static void ClosePids(IEnumerable<int> pids, TimeSpan? grace = null)
        {
            var g = grace ?? TimeSpan.FromMilliseconds(500);
            foreach (var pid in pids)
            {
                try
                {
                    var p = Process.GetProcessById(pid);
                    try { p.CloseMainWindow(); } catch { }
                    if (!p.WaitForExit((int)g.TotalMilliseconds))
                    {
                        try { p.Kill(true); } catch { }
                    }
                }
                catch { /* ignored */ }
            }
        }
    }
}

