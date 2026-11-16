$ErrorActionPreference = "Stop"

# ------------------------------------------------------------
# Helper functions
# ------------------------------------------------------------

### Create section headers
function Write-SectionHeader {
    param (
        [Parameter(Mandatory)]
        [string]$Title
    )

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host ""
}

### Create a numbered list of items to choose from
function Select-NumberedItem {
    param (
        [Parameter(Mandatory)]
        [string[]]$Items,

        [string]$Prompt = "Select an option"
    )

    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host "[$($i + 1)] $($Items[$i])"
    }

    do {
        $selection = Read-Host $Prompt

        if ($selection -match '^\d+$' -and
            [int]$selection -ge 1 -and
            [int]$selection -le $Items.Count) {

            return $Items[[int]$selection - 1]
        }

        Write-Host "Invalid selection. Enter a number between 1 and $($Items.Count)." -ForegroundColor Red

    } while ($true)
}

### Prompt for value entry, displaying default value
function Read-ValueWithDefault {
    param (
        [Parameter(Mandatory)]
        [string]$Prompt,

        [Parameter(Mandatory)]
        [string]$DefaultValue
    )

    $value = Read-Host "$Prompt [$DefaultValue]"

    if ([string]::IsNullOrWhiteSpace($value)) {
        return $DefaultValue
    }

    return $value.Trim()
}

# ------------------------------------------------------------
# Locate Bicep template
# ------------------------------------------------------------

Write-SectionHeader -Title "Locating Bicep file..."

## If the Bicep file is renamed, this must be edited ##
$templateFile = Join-Path $PSScriptRoot "ScalingPlan.bicep"

if (-not (Test-Path -LiteralPath $templateFile -PathType Leaf)) {
    throw "Bicep template not found: $templateFile"
}

$templateFile = (Resolve-Path -LiteralPath $templateFile).Path

Write-Host ""
Write-Host "Bicep template:" -ForegroundColor Green
Write-Host "  $templateFile"


# ------------------------------------------------------------
# Azure sign-in check
# ------------------------------------------------------------

Write-SectionHeader -Title "Checking Azure sign-in status..."

$context = Get-AzContext -ErrorAction SilentlyContinue

if (-not $context) {
    Write-Host ""
    Write-Host "No Azure context found. Signing in..." -ForegroundColor Yellow

    Connect-AzAccount -ErrorAction Stop | Out-Null
}


# ------------------------------------------------------------
# Subscription selection
# ------------------------------------------------------------

Write-SectionHeader -Title "Subscription selection..."

$subscriptions = @(
    Get-AzSubscription -ErrorAction Stop |
        Where-Object { $_.State -eq "Enabled" } |
        Sort-Object Name
)

$selectedSubscriptionName = Select-NumberedItem -Prompt "Select the Azure subscription:" -Items $subscriptions.Name

$selectedSubscription = $subscriptions | Where-Object { $_.Name -eq $selectedSubscriptionName }

Set-AzContext -SubscriptionId $selectedSubscription.Id -ErrorAction Stop | Out-Null

Write-Host ""
Write-Host "Using subscription:" -ForegroundColor Green
Write-Host "  Name: $($selectedSubscription.Name)"
Write-Host "  ID:   $($selectedSubscription.Id)"

# ------------------------------------------------------------
# Customer code
# ------------------------------------------------------------

Write-SectionHeader -Title "Customer Identifier - naming convention"

do {
    $customerCode = Read-Host "`nEnter customer code"

    if (-not [string]::IsNullOrWhiteSpace($customerCode)) {
        $customerCode = $customerCode.Trim().ToLower()
    }

    if ([string]::IsNullOrWhiteSpace($customerCode)) {
        Write-Warning "Customer code cannot be blank."
        $validCustomerCode = $false
    }
    elseif ($customerCode -notmatch '^[a-z0-9-]+$') {
        Write-Warning "Customer code can contain only lowercase letters, numbers and hyphens."
        $validCustomerCode = $false
    }
    else {
        $validCustomerCode = $true
    }

} until ($validCustomerCode)


# ------------------------------------------------------------
# Scaling Plan Configuration
# ------------------------------------------------------------
Write-SectionHeader -Title "Scaling Plan Configuration:"
# ------------------------------------------------------------

# ------------------------------------------------------------
# Host Pool Selection
$hostPoolReferences = @()

$hostPools = @(Get-AzWvdHostPool | Sort-Object Name)

if ($hostPools.Count -gt 0) {

    $selectedHostPoolName = Select-NumberedItem -Items $hostPools.Name -Prompt "Select Host Pool:"

    $selectedHostPool = $hostPools |
        Where-Object { $_.Name -eq $selectedHostPoolName }

    $hostPoolReferences = @(
        @{
            hostPoolArmPath    = $selectedHostPool.Id
            scalingPlanEnabled = $true
        }
    )

    Write-Host ""
    Write-Host "Selected Host Pool: $selectedHostPoolName" -ForegroundColor Green

}
else {

    Write-Host ""
    Write-Host "No existing AVD host pools found. Scaling plan will be created without a host pool association." -ForegroundColor Yellow
}

# ------------------------------------------------------------
# Scaling Plan Name
$scalingPlanName = Read-ValueWithDefault -Prompt "Enter Scaling Plan Name:" -DefaultValue "$customerCode-AVD-SP"

# ------------------------------------------------------------
# Friendly Name
$friendlyName = $scalingPlanName

# ------------------------------------------------------------
# Description
$scalingPlanDescription = ""

# ------------------------------------------------------------
# Scaling plan Time zone
$timeZone = Read-ValueWithDefault -Prompt "Choose Time Zone:" -DefaultValue "GMT Standard Time"

# ------------------------------------------------------------
# Location for Scaling plan
if (-not $selectedHostPool) {
    $location = Read-ValueWithDefault -Prompt "Location for the Scaling Plan:" -DefaultValue "uksouth"
}
else {
    $location = $selectedHostPool.location
    Write-Host ""
    Write-Host "Selected Host Pool is $selectedHostPoolName. Scaling plan will be created in the same region ($location)."
    Write-Host ""
}

# ------------------------------------------------------------
# Default Tags
$tags = @{
    phx_created = "yes"
}

# ------------------------------------------------------------
# Define Host Pool Type
Write-Host ""
$hostPoolType = Select-NumberedItem -Items "Pooled","Personal" -Prompt "Select Host Pool type:"
Write-Host ""

# ------------------------------------------------------------
# Scaling Method Selection
if ($hostPoolType -eq "Pooled") {
    Write-Host ""
    $selectedScalingMethod = Select-NumberedItem -Items "CreateDeletePowerManage","PowerManage" -Prompt "Select Scaling Method:"
    Write-Host ""
    Write-Host "Selected Scaling Method: $selectedScalingMethod" -ForegroundColor Green
    Write-Host ""
}
else {
    Write-Host ""
    $selectedScalingMethod = "PowerManage"
    Write-Host ""
    Write-Host "Note: CreateDeletePowerManage is only available for Pooled host pools using a Session Host Configuration." -ForegroundColor Red
    Write-Host "Selected Scaling Method: $selectedScalingMethod" -ForegroundColor Green
    Write-Host ""
}

# ------------------------------------------------------------
# Build Scaling Schedule
$schedule = @{
    name                           = 'weekdays_schedule'
    daysOfWeek                     = @(
        'Monday'
        'Tuesday'
        'Wednesday'
        'Thursday'
        'Friday'
    )
    scalingMethod                  = $selectedScalingMethod

    rampUpStartTime                = @{
        hour   = 8
        minute = 0
    }
    rampUpLoadBalancingAlgorithm   = 'BreadthFirst'
    rampUpMinimumHostsPct          = 100
    rampUpCapacityThresholdPct     = 60

    peakStartTime                  = @{
        hour   = 9
        minute = 0
    }
    peakLoadBalancingAlgorithm     = 'BreadthFirst'

    rampDownStartTime              = @{
        hour   = 18
        minute = 0
    }
    rampDownLoadBalancingAlgorithm = 'DepthFirst'
    rampDownMinimumHostsPct        = 100
    rampDownCapacityThresholdPct   = 90
    rampDownWaitTimeMinutes        = 30
    rampDownStopHostsWhen          = 'ZeroActiveSessions'
    rampDownNotificationMessage    = 'You will be logged off in 30 min. Make sure to save your work.'

    offPeakStartTime               = @{
        hour   = 22
        minute = 0
    }
    offPeakLoadBalancingAlgorithm  = 'DepthFirst'

    rampDownForceLogoffUsers       = $false

    generalActiveMinimumHostsPct   = 100
    generalMaximumHostPoolSize     = 10
    generalMinimumHostPoolSize     = 5
}

### Include CreateDelete settings if CreateDeletePowerManage is selected
if ($selectedScalingMethod -eq 'CreateDeletePowerManage') {
    $schedule.createDelete = @{
        rampUpMaximumHostPoolSize   = 10
        rampUpMinimumHostPoolSize   = 5
        rampDownMaximumHostPoolSize = 10
        rampDownMinimumHostPoolSize = 5
    }
}

$schedules = @($schedule)

## Optionally output Schedules to check
## Write-Host ""
## Write-Host "Schedules:" -ForegroundColor Cyan
## Write-Host ($schedules | ConvertTo-Json -Depth 10)

# ------------------------------------------------------------
# Define Exclusion tag
$exclusionTag = Read-ValueWithDefault -Prompt "Exclusion tag:" -DefaultValue "No_Scale"


# ------------------------------------------------------------
# Deployment parameters
# ------------------------------------------------------------

$deploymentParameters = @{
    TemplateFile             = $templateFile
    scalingPlanName          = $scalingPlanName
    friendlyName             = $friendlyName
    hostPoolReferences       = $hostPoolReferences
    scalingPlanDescription   = $scalingPlanDescription
    hostPoolType             = $hostPoolType
    timeZone                 = $timeZone
    schedules                = $schedules
    location                 = $location
    exclusionTag             = $exclusionTag
    tags                     = $tags
}

# ------------------------------------------------------------
# Validate Bicep deployment
# ------------------------------------------------------------
Write-SectionHeader -Title "Validating deployment:"

Write-Host ""
Write-Host "Validating deployment..." -ForegroundColor Cyan

$validationResult = Test-AzResourceGroupDeployment @deploymentParameters

if ($validationResult) {
    Write-Host ""
    Write-Host "Deployment validation returned errors:" -ForegroundColor Red

    $validationResult |
        Format-List |
        Out-String |
        Write-Host

    throw "Deployment validation failed."
}

Write-Host "Deployment validation completed successfully." -ForegroundColor Green

# ------------------------------------------------------------
# Deploy Scaling Plan
# ------------------------------------------------------------
Write-SectionHeader -Title "Deploying Scaling Plan:"

Write-Host ""
Write-Host "Creating Scaling Plan..." -ForegroundColor Cyan

$deploymentName = "$customerCode-SP-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

$deploymentParameters["Name"] = $deploymentName

$deployment = New-AzResourceGroupDeployment @deploymentParameters

Write-Host ""
Write-Host "Deployment completed successfully." -ForegroundColor Green
Write-Host "  Deployment name: $deploymentName"
Write-Host "  Image template:  $imageTemplateName"


# ------------------------------------------------------------
# Display deployment outputs
# ------------------------------------------------------------

Write-SectionHeader -Title "Deployment Results:"

if ($deployment.Outputs) {
    Write-Host ""
    Write-Host "Deployment outputs:" -ForegroundColor Cyan

    foreach ($outputName in $deployment.Outputs.Keys) {
        $outputValue = $deployment.Outputs[$outputName].Value

        if ($outputValue -is [array]) {
            $outputValue = $outputValue -join ", "
        }

        Write-Host "  $outputName : $outputValue"
    }
}