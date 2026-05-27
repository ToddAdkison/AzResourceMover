@{
    RootModule        = 'AzRM.Operations.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a1b2c3d4-0004-0004-0004-a1b2c3d4e5f6'
    Author            = 'AzResourceMover'
    Description       = 'Azure API validation, move execution, and report assembly for the AzResourceMover toolkit.'
    PowerShellVersion = '5.1'
    RequiredModules   = @(
        @{ ModuleName = 'AzRM.Output';   ModuleVersion = '1.0.0' }
        @{ ModuleName = 'AzRM.Preflight'; ModuleVersion = '1.0.0' }
    )
    FunctionsToExport = @(
        'Invoke-MoveValidation',
        'Invoke-ResourceMove',
        'Write-MoveResult',
        'New-Report',
        'Write-Report'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
