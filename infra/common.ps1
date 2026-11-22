# Shared settings and helpers, dot-sourced by deploy.ps1, run-pipeline.ps1 and teardown.ps1.

$RepoRoot       = Split-Path -Parent $PSScriptRoot
$DeploymentName = "adf-etl"
$PipelineName   = "pl_customers_etl"

# Runs the Azure CLI and stops the script on failure. Returns the raw output text.
function Invoke-Az {
    $output = & az @args --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: az $($args -join ' ')" }
    $output -join "`n"
}

# Same as Invoke-Az, parsed from JSON.
function Invoke-AzJson {
    Invoke-Az @args --output json | ConvertFrom-Json
}

function Get-DeploymentOutputs([string]$ResourceGroup) {
    Invoke-AzJson deployment group show --resource-group $ResourceGroup `
        --name $DeploymentName --query properties.outputs
}

$Subscription = Invoke-AzJson account show
Write-Host "Azure subscription: $($Subscription.name) ($($Subscription.user.name))"
