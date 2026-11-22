# Deploys main.bicep (storage, Data Factory, datasets, data flow, pipeline) and uploads the sample CSV.
# Safe to re-run: Bicep deployments are declarative and the upload overwrites the file.
param(
    [string]$ResourceGroup = "rg-adf-etl-demo",
    [string]$Location = "eastus"
)
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\common.ps1"

Write-Host "[1/4] Registering resource providers (first time only, can take a minute)"
foreach ($namespace in "Microsoft.Storage", "Microsoft.DataFactory") {
    Invoke-Az provider register --namespace $namespace --wait | Out-Null
}

Write-Host "[2/4] Resource group $ResourceGroup ($Location)"
Invoke-Az group create --name $ResourceGroup --location $Location | Out-Null

Write-Host "[3/4] Deploying main.bicep"
$outputs = Invoke-AzJson deployment group create --resource-group $ResourceGroup `
    --name $DeploymentName --template-file "$PSScriptRoot\main.bicep" --query properties.outputs
$storage = $outputs.storageAccountName.value

Write-Host "[4/4] Uploading sample-data/customers.csv to $storage/input"
Invoke-Az storage blob upload --account-name $storage --auth-mode key `
    --container-name input --name customers.csv `
    --file "$RepoRoot\sample-data\customers.csv" --overwrite | Out-Null

Write-Host "Done. Data Factory: $($outputs.dataFactoryName.value). Run the pipeline with .\infra\run-pipeline.ps1"
