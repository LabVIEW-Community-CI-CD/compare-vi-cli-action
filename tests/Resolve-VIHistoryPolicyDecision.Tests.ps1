Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Resolve-VIHistoryPolicyDecision' -Tag 'Unit' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        . (Join-Path $repoRoot 'tools' 'Resolve-VIHistoryPolicyDecision.ps1')
    }

    It 'returns strict pass when required diffs are present' {
        $result = Resolve-VIHistoryPolicyDecision -TargetPath 'fixtures/vi-attr/Head.vi' -RequireDiff:$true -MinDiffs 1 -Comparisons 2 -Diffs 2 -Status 'diff'
        $result.policyClass | Should -Be 'strict'
        $result.outcome | Should -Be 'pass'
        $result.gateOutcome | Should -Be 'pass'
        $result.hardFail | Should -BeFalse
    }

    It 'returns strict failure when summary row is missing' {
        $result = Resolve-VIHistoryPolicyDecision -TargetPath 'fixtures/vi-attr/Head.vi' -RequireDiff:$true -MinDiffs 1 -Missing
        $result.outcome | Should -Be 'fail'
        $result.hardFail | Should -BeTrue
        $result.reasonCode | Should -Be 'missing-summary-row'
    }

    It 'returns strict failure when diffs are below threshold' {
        $result = Resolve-VIHistoryPolicyDecision -TargetPath 'fixtures/vi-attr/Head.vi' -RequireDiff:$true -MinDiffs 2 -Comparisons 2 -Diffs 1 -Status 'diff'
        $result.outcome | Should -Be 'fail'
        $result.reasonCode | Should -Be 'insufficient-diffs'
    }

    It 'returns strict failure when status is not diff' {
        $result = Resolve-VIHistoryPolicyDecision -TargetPath 'fixtures/vi-attr/Head.vi' -RequireDiff:$true -MinDiffs 1 -Comparisons 2 -Diffs 2 -Status 'match'
        $result.outcome | Should -Be 'fail'
        $result.reasonCode | Should -Be 'strict-status-mismatch'
    }

    It 'returns smoke warning when summary row is missing' {
        $result = Resolve-VIHistoryPolicyDecision -TargetPath 'fixtures/vi-attr/Base.vi' -RequireDiff:$false -MinDiffs 0 -Missing
        $result.policyClass | Should -Be 'smoke'
        $result.outcome | Should -Be 'warn'
        $result.warning | Should -BeTrue
        $result.gateOutcome | Should -Be 'pass'
    }

    It 'returns smoke warning for zero comparisons' {
        $result = Resolve-VIHistoryPolicyDecision -TargetPath 'fixtures/vi-attr/Base.vi' -RequireDiff:$false -MinDiffs 0 -Comparisons 0 -Diffs 0 -Status 'match'
        $result.outcome | Should -Be 'warn'
        $result.reasonCode | Should -Be 'zero-comparisons'
    }

    It 'returns smoke pass for non-diff metadata outcomes' {
        $result = Resolve-VIHistoryPolicyDecision -TargetPath 'fixtures/vi-attr/Base.vi' -RequireDiff:$false -MinDiffs 0 -Comparisons 1 -Diffs 0 -Status 'match'
        $result.outcome | Should -Be 'pass'
        $result.gateOutcome | Should -Be 'pass'
        $result.warning | Should -BeFalse
    }
}

