@{
    RootModule        = 'AzRM.Output.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a1b2c3d4-0001-0001-0001-a1b2c3d4e5f6'
    Author            = 'AzResourceMover'
    Description       = 'Shared console output helpers for the AzResourceMover toolkit.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Write-Header', 'Write-Section', 'Write-Log')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
