using System.Linq;
using CompareVi.Shared;
using Xunit;

namespace CompareVi.Shared.Tests
{
    public class ProcSnapshotTests
    {
        [Fact]
        public void Capture_ReturnsCollectionsAndNoDuplicates()
        {
            var snap = ProcSnapshot.Capture();
            Assert.NotNull(snap.LabViewPids);
            Assert.NotNull(snap.LvComparePids);
            Assert.NotNull(snap.LabViewCliPids);
            Assert.NotNull(snap.GcliPids);
            Assert.Equal(snap.LabViewPids.Distinct().Count(), snap.LabViewPids.Count);
            Assert.Equal(snap.LvComparePids.Distinct().Count(), snap.LvComparePids.Count);
            Assert.Equal(snap.LabViewCliPids.Distinct().Count(), snap.LabViewCliPids.Count);
            Assert.Equal(snap.GcliPids.Distinct().Count(), snap.GcliPids.Count);
        }

        [Fact]
        public void NewLabViewSince_ComputesSetDifference()
        {
            var before = new ProcSnapshot(new[] { 1, 2, 3 }, new int[0]);
            var after  = new ProcSnapshot(new[] { 2, 3, 4 }, new int[0]);
            var delta = after.NewLabViewSince(before);
            Assert.Single(delta);
            Assert.Equal(4, delta[0]);
        }

        [Fact]
        public void Constructor_NormalizesAllPidSets()
        {
            var snapshot = new ProcSnapshot(
                new[] { 3, 2, 3, 1 },
                new[] { 10, 10, 9 },
                new[] { 7, 8, 7 },
                new[] { 5, 6, 5 });

            Assert.Equal(new[] { 1, 2, 3 }, snapshot.LabViewPids);
            Assert.Equal(new[] { 9, 10 }, snapshot.LvComparePids);
            Assert.Equal(new[] { 7, 8 }, snapshot.LabViewCliPids);
            Assert.Equal(new[] { 5, 6 }, snapshot.GcliPids);
        }
    }
}

