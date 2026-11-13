$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

foreach ($Case in @(
    @{ File = "Test-Package.ps1"; Name = "Expect-Failure" },
    @{ File = "Test-Install.ps1"; Name = "Expect-InstallFailure" }
)) {
    $Tokens = $null
    $Errors = $null
    $Syntax = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot $Case.File), [ref]$Tokens, [ref]$Errors)
    if ($Errors.Count -ne 0) { throw "Cannot parse $($Case.File)" }
    $Function = $Syntax.Find({
        param($Node)
        $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq $Case.Name
    }, $false)
    if ($null -eq $Function) { throw "Missing $($Case.Name)" }
    . ([scriptblock]::Create($Function.Extent.Text))
}

function Invoke-TestInstall($Bundle, $Overrides) {
    if ($Bundle -eq "fail") { throw "synthetic rejection" }
}

function Assert-Rejected([scriptblock]$Action) {
    $Rejected = $false
    try { & $Action } catch { $Rejected = $true }
    if (-not $Rejected) { throw "Failure assertion accepted an action that should fail the test" }
}

Assert-Rejected { Expect-Failure {} "synthetic" }
Expect-Failure { throw "synthetic rejection" } "synthetic"
Assert-Rejected { Expect-Failure { throw "other error" } "synthetic" }
Assert-Rejected { Expect-InstallFailure "success" "synthetic" }
Expect-InstallFailure "fail" "synthetic"
Assert-Rejected { Expect-InstallFailure "fail" "other" }
Write-Output "Positive and negative failure-assertion controls passed"
