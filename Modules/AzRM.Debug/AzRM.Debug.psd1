@{
    RootModule        = 'AzRM.Debug.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a1b2c3d4-0005-0005-0005-a1b2c3d4e5f6'
    Author            = 'AzResourceMover'
    Description       = 'Debug logging for the AzResourceMover toolkit. Captures HTTP payloads, context switches, ARM exports, and resource lists in a timestamped log file.'
    PowerShellVersion = '5.1'
    RequiredModules   = @(
        @{ ModuleName = 'AzRM.Output'; ModuleVersion = '1.0.0' }
    )
    FunctionsToExport = @(
        'Initialize-DebugLog',
        'Close-DebugLog',
        'Get-DebugLogPath',
        'Test-DebugEnabled',
        'Write-DebugLog',
        'Write-DebugSection',
        'Write-DebugContextSwitch',
        'Write-DebugResourceList',
        'Write-DebugArmExport',
        'Write-DebugRequest',
        'Write-DebugResponse'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
