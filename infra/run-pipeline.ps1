# Triggers the pipeline once, waits for it to finish, and saves the evidence:
# run details, per-activity results, and the output CSV files.
param(
    [string]$ResourceGroup = "rg-adf-etl-demo"
)
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\common.ps1"

$outputs = Get-DeploymentOutputs $ResourceGroup
$factory = $outputs.dataFactoryName.value
$storage = $outputs.storageAccountName.value
$factoryArgs = @("--resource-group", $ResourceGroup, "--factory-name", $factory)

Invoke-Az extension add --name datafactory --upgrade | Out-Null

$started = [DateTime]::UtcNow
$runId = (Invoke-AzJson datafactory pipeline create-run @factoryArgs --name $PipelineName).runId
Write-Host "Pipeline run $runId started (the data flow cluster needs a few minutes to start)"

do {
    Start-Sleep -Seconds 20
    $runJson = Invoke-Az datafactory pipeline-run show @factoryArgs --run-id $runId --output json
    $status = ($runJson | ConvertFrom-Json).status
    Write-Host "  $([DateTime]::UtcNow.ToString('HH:mm:ss')) $status"
} while ($status -in "Queued", "InProgress", "Canceling")

$activitiesJson = Invoke-Az datafactory activity-run query-by-pipeline-run @factoryArgs --run-id $runId `
    --last-updated-after $started.AddMinutes(-5).ToString("o") `
    --last-updated-before ([DateTime]::UtcNow.AddMinutes(5).ToString("o")) --output json

# ---------- Save evidence ----------
$evidenceDir = Join-Path $RepoRoot "evidence"
$outputDir = Join-Path $evidenceDir "output"
New-Item -ItemType Directory -Force $outputDir | Out-Null

# Keep the subscription and tenant IDs out of the committed evidence.
# -replace ignores case: ADF writes resource IDs in upper case.
function Save-Redacted([string]$Name, [string]$Content) {
    $redacted = $Content `
        -replace [regex]::Escape($Subscription.id), "<SUBSCRIPTION_ID>" `
        -replace [regex]::Escape($Subscription.tenantId), "<TENANT_ID>"
    [IO.File]::WriteAllText((Join-Path $evidenceDir $Name), $redacted + "`n")
}
Save-Redacted "pipeline-run.json" $runJson
Save-Redacted "activity-runs.json" $activitiesJson

foreach ($activity in ($activitiesJson | ConvertFrom-Json).value) {
    Write-Host ("  {0,-24} {1,-15} {2,-10} {3,6:N1} s" -f `
        $activity.activityName, $activity.activityType, $activity.status, ($activity.durationInMs / 1000))
}

$blobs = (Invoke-AzJson storage blob list --account-name $storage --auth-mode key --container-name output).name
Save-Redacted "output-container-listing.txt" ($blobs -join "`n")
foreach ($blob in $blobs | Where-Object { $_ -like "*.csv" }) {
    $local = Join-Path $outputDir ($blob -replace "/", "_")
    Invoke-Az storage blob download --account-name $storage --auth-mode key `
        --container-name output --name $blob --file $local --overwrite | Out-Null
    Write-Host "  downloaded output/$blob"
}

if ($status -ne "Succeeded") { throw "Pipeline run finished with status $status" }
Write-Host "Pipeline Succeeded. Evidence saved to evidence/"
