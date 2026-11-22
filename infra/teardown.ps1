# Deletes the resource group and everything in it (storage account, data, Data Factory).
param(
    [string]$ResourceGroup = "rg-adf-etl-demo"
)
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\common.ps1"

Write-Host "Deleting resource group $ResourceGroup (takes a few minutes)..."
Invoke-Az group delete --name $ResourceGroup --yes | Out-Null
Write-Host "Teardown complete."
