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

        public ProcSnapshot(IEnumerable<int> lvPids, IEnumerable<int> lvcPids)
        {
            LabViewPids = lvPids?.Distinct().OrderBy(x => x).ToArray() ?? Array.Empty<int>();
            LvComparePids = lvcPids?.Distinct().OrderBy(x => x).ToArray() ?? Array.Empty<int>();
        }

        public static ProcSnapshot Capture()
        {
            IEnumerable<int> get(string name)
            {
                try { return Process.GetProcessesByName(name).Select(p => p.Id); }
                catch { return Array.Empty<int>(); }
            }
            return new ProcSnapshot(get("LabVIEW"), get("LVCompare"));
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

