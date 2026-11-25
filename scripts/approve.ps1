param(
  [Parameter(Mandatory = $true)][string]$Incident,
  [Parameter(Mandatory = $true)][ValidateSet("approve", "reject")][string]$Decision,
  [string]$Table = "sentinelops-dev-agent-audit",
  [string]$Profile = "sentinel"
)

$tmp = New-TemporaryFile
('{":i":{"S":"' + $Incident + '"}}') | Set-Content $tmp -Encoding ascii
$rows = aws dynamodb query --table-name $Table --key-condition-expression "incident_id = :i" --expression-attribute-values "file://$tmp" --output json --profile $Profile | ConvertFrom-Json
Remove-Item $tmp

$pending = $rows.Items | Where-Object { $_.kind.S -eq "approval_pending" } | Sort-Object { $_.ts.S } | Select-Object -Last 1
if (-not $pending) { Write-Host "No pending approval found for $Incident"; exit 1 }

$req = $pending.payload.S | ConvertFrom-Json
Write-Host "Action: $($req.action)"
Write-Host "Reason: $($req.reason)"

if ($Decision -eq "approve") {
  aws stepfunctions send-task-success --task-token $req.token --task-output '{}' --profile $Profile
  Write-Host "Approved."
} else {
  aws stepfunctions send-task-failure --task-token $req.token --error Rejected --cause "Rejected by operator" --profile $Profile
  Write-Host "Rejected."
}
