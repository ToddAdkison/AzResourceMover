@{
    RootModule        = 'AzRM.Preflight.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a1b2c3d4-0002-0002-0002-a1b2c3d4e5f6'
    Author            = 'AzResourceMover'
    Description       = 'Prerequisite checks and resource collection for the AzResourceMover toolkit.'
    PowerShellVersion = '5.1'
    RequiredModules   = @(
        @{ ModuleName = 'AzRM.Output'; ModuleVersion = '1.0.0' }
    )
    FunctionsToExport = @(
        'Test-ModuleAvailable',
        'Test-AzureSession',
        'Test-ResourceGroupExists',
        'Get-SourceResources',
        'Test-IsTopLevel',
        'Select-TopLevelResources',
        'Resolve-ResourceIds'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
