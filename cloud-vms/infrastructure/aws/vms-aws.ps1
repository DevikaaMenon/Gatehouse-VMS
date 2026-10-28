<#
.SYNOPSIS
  Gatehouse VMS on AWS (Free Tier): deploy, inspect, pause and remove the cloud setup.

.EXAMPLE
  .\vms-aws.ps1 check      # tools installed, AWS credentials work, terraform.tfvars present
  .\vms-aws.ps1 deploy     # create / update everything (also re-allows your current IP)
  .\vms-aws.ps1 status     # server, database, dashboard URL, health
  .\vms-aws.ps1 password   # admin password (user name: admin)
  .\vms-aws.ps1 logs       # last hour of application logs (add -Follow to keep watching)
  .\vms-aws.ps1 update     # pull the latest code from GitHub on the server and restart
  .\vms-aws.ps1 stop       # stop server + database (saves free-tier hours / credits)
  .\vms-aws.ps1 start
  .\vms-aws.ps1 destroy    # delete everything, including the bucket contents and the database
#>
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [ValidateSet("check", "deploy", "status", "password", "logs", "update", "stop", "start", "destroy")]
  [string]$Command,
  [switch]$Follow
)
$ErrorActionPreference = "Stop"
$Tf = Join-Path $PSScriptRoot "terraform"

function Need($exe, $hint) {
  if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { throw "$exe is not installed. $hint" }
}

# run terraform / aws and stop on a non-zero exit code
function Tf { & terraform "-chdir=$Tf" @args; if ($LASTEXITCODE -ne 0) { throw "terraform $($args[0]) failed" } }
function Aws { & aws --region $script:Region @args; if ($LASTEXITCODE -ne 0) { throw "aws $($args[0]) $($args[1]) failed" } }

function Get-Out($name) {
  $v = & terraform "-chdir=$Tf" output -raw $name 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $v) { throw "Nothing deployed yet (no '$name' output). Run: .\vms-aws.ps1 deploy" }
  return $v
}

function Get-MyCidr {
  $ip = (Invoke-RestMethod -Uri "https://checkip.amazonaws.com" -TimeoutSec 10).Trim()
  return "$ip/32"
}

function Test-Setup {
  Need terraform "Install it with: winget install Hashicorp.Terraform"
  Need aws "Install it with: winget install Amazon.AWSCLI   then run: aws configure"
  $account = & aws sts get-caller-identity --query Account --output text 2>$null
  if ($LASTEXITCODE -ne 0) { throw "AWS credentials are not set up. Run: aws configure" }
  if (-not (Test-Path (Join-Path $Tf "terraform.tfvars"))) {
    throw "Copy $Tf\terraform.tfvars.example to terraform.tfvars and set alert_email first."
  }
  Write-Host "AWS account $account" -ForegroundColor Green
}

if ($Command -notin @("check", "deploy", "destroy")) { $Region = Get-Out region }

switch ($Command) {
  "check" {
    Test-Setup
    Write-Host "Ready to deploy." -ForegroundColor Green
  }

  "deploy" {
    Test-Setup
    $cidr = Get-MyCidr
    Write-Host "The dashboard will be reachable from $cidr only."
    Tf init -input=false
    Tf apply "-var=allowed_cidr=$cidr"
    Write-Host ""
    Write-Host "The server is now building the app (first time: roughly 20-40 minutes on a t3.micro)." -ForegroundColor Yellow
    Write-Host "Check progress with:  .\vms-aws.ps1 status"
  }

  "status" {
    $id = Get-Out instance_id
    $state, $ip = (Aws ec2 describe-instances --instance-ids $id `
        --query "Reservations[0].Instances[0].[State.Name,PublicIpAddress]" --output text) -split "\s+"
    $dbState = Aws rds describe-db-instances --db-instance-identifier (Get-Out db_identifier) `
      --query "DBInstances[0].DBInstanceStatus" --output text
    Write-Host "Server:    $state"
    Write-Host "Database:  $dbState"
    if ($state -eq "running" -and $ip -and $ip -ne "None") {
      Write-Host "Dashboard: http://$ip"
      try {
        $null = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 "http://$ip/api/health"
        Write-Host "Health:    OK" -ForegroundColor Green
      } catch {
        Write-Host "Health:    not answering yet (still building, or your IP changed: run deploy again)" -ForegroundColor Yellow
      }
    }
  }

  "password" {
    $pw = Aws ssm get-parameter --with-decryption --name (Get-Out admin_password_parameter) `
      --query Parameter.Value --output text
    Write-Host "user name: admin"
    Write-Host "password:  $pw"
  }

  "logs" {
    if ($Follow) { Aws logs tail (Get-Out log_group) --since 1h --follow }
    else { Aws logs tail (Get-Out log_group) --since 1h }
  }

  "update" {
    $cmd = Aws ssm send-command --instance-ids (Get-Out instance_id) --document-name AWS-RunShellScript `
      --timeout-seconds 3600 --parameters "commands=/opt/gatehouse/deploy.sh" --comment "gatehouse update" `
      --query Command.CommandId --output text
    Write-Host "Rebuilding on the server (command $cmd). This takes several minutes; then run: .\vms-aws.ps1 status"
  }

  "stop" {
    Aws ec2 stop-instances --instance-ids (Get-Out instance_id) --output text | Out-Null
    Aws rds stop-db-instance --db-instance-identifier (Get-Out db_identifier) --output text | Out-Null
    Write-Host "Stopping. AWS starts a stopped database again by itself after 7 days." -ForegroundColor Yellow
  }

  "start" {
    Aws rds start-db-instance --db-instance-identifier (Get-Out db_identifier) --output text | Out-Null
    Aws ec2 start-instances --instance-ids (Get-Out instance_id) --output text | Out-Null
    Write-Host "Starting. The public IP changes after a stop; run .\vms-aws.ps1 status in a few minutes."
  }

  "destroy" {
    Test-Setup
    Tf destroy "-var=allowed_cidr=$(Get-MyCidr)"
  }
}
