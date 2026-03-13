Describe 'CLI parameters' {
    It 'defines the expected automation parameters on the root script' {
        $repoRoot = Split-Path -Path $PSScriptRoot -Parent
        $scriptPath = Join-Path -Path $repoRoot -ChildPath 'stardew-save-bridge.ps1'
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
        $paramNames = $ast.ParamBlock.Parameters.Name.VariablePath.UserPath

        $paramNames | Should -Contain 'Action'
        $paramNames | Should -Contain 'SaveSlot'
        $paramNames | Should -Contain 'DeviceId'
        $paramNames | Should -Contain 'BackupId'
        $paramNames | Should -Contain 'RestoreTarget'
        $paramNames | Should -Contain 'DryRun'
        $paramNames | Should -Contain 'Force'
        $errors.Count | Should -Be 0
    }
}
