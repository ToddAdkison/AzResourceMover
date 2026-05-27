@{
    RootModule        = 'AzRM.Analysis.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a1b2c3d4-0003-0003-0003-a1b2c3d4e5f6'
    Author            = 'AzResourceMover'
    Description       = 'Dependency checks (locks, cross-group deps, naming conflicts) for the AzResourceMover toolkit.'
    PowerShellVersion = '5.1'
    RequiredModules   = @(
        @{ ModuleName = 'AzRM.Output'; ModuleVersion = '1.0.0' }
    )
    FunctionsToExport = @(
        'Get-ResourceLockStatus',
        'Get-CrossGroupDependencies',
        'Get-NamingConflicts'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
