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

function Select-NumberedItem {
    param (
        [Parameter(Mandatory)]
        [string]$Prompt,

        [Parameter(Mandatory)]
        [array]$Items,

        [Parameter(Mandatory)]
        [scriptblock]$DisplayProperty
    )

    if ($Items.Count -eq 0) {
        throw "No items were found for: $Prompt"
    }

    Write-SectionHeader -Title $Prompt

    for ($i = 0; $i -lt $Items.Count; $i++) {
        $displayValue = & $DisplayProperty $Items[$i]
        Write-Host "  [" -NoNewline -ForegroundColor DarkGray
        Write-Host "$($i + 1)" -NoNewline -ForegroundColor Yellow
        Write-Host "] " -NoNewline -ForegroundColor DarkGray
        Write-Host $displayValue -ForegroundColor White
    }

    do {
        $selection = Read-Host "`nSelect an option"
        $selectionNumber = 0

        $validSelection = (
            [int]::TryParse($selection, [ref]$selectionNumber) -and
            $selectionNumber -ge 1 -and
            $selectionNumber -le $Items.Count
        )

        if (-not $validSelection) {
            Write-Warning "Enter a number between 1 and $($Items.Count)."
        }

    } until ($validSelection)

    return $Items[$selectionNumber - 1]
}


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


function Read-IntegerWithDefault {
    param (
        [Parameter(Mandatory)]
        [string]$Prompt,

        [Parameter(Mandatory)]
        [int]$DefaultValue,

        [int]$MinimumValue = 1
    )

    do {
        $value = Read-Host "$Prompt [$DefaultValue]"

        if ([string]::IsNullOrWhiteSpace($value)) {
            return $DefaultValue
        }

        $parsedValue = 0

        $validValue = (
            [int]::TryParse($value, [ref]$parsedValue) -and
            $parsedValue -ge $MinimumValue
        )

        if (-not $validValue) {
            Write-Warning "Enter a whole number greater than or equal to $MinimumValue."
        }

    } until ($validValue)

    return $parsedValue
}


function Read-YesNo {
    param (
        [Parameter(Mandatory)]
        [string]$Prompt,

        [ValidateSet("Y", "N")]
        [string]$Default = "N"
    )

    do {
        $response = Read-Host "$Prompt [$Default]"

        if ([string]::IsNullOrWhiteSpace($response)) {
            $response = $Default
        }

        $response = $response.Trim().ToUpper()

        if ($response -notin @("Y", "YES", "N", "NO")) {
            Write-Warning "Enter Y or N."
        }

    } until ($response -in @("Y", "YES", "N", "NO"))

    return $response -in @("Y", "YES")
}

## This function checks for available VM SKUs and prompts user to choose one
function Select-VMSize {
    param (
        [Parameter(Mandatory)]
        [string]$Location
    )

    $commonSkuNames = @(
        "Standard_D2as_v5",
        "Standard_D4as_v5",
        "Standard_D8as_v5",
        "Standard_D16as_v5",
        "Standard_D32as_v5",
        "Standard_D48as_v5",
        "Standard_D64as_v5",
        "Standard_D96as_v5"
    )

    # Turns a raw SKU into a simple object, or returns nothing if the SKU is
    # unusable (location-restricted, or missing/invalid vCPU or memory data).
    function ConvertTo-VmSizeInfo {
        param($Sku)

        # Only location-level restrictions make a size undeployable.
        # Zone restrictions are fine when no zone is requested.
        if (@($Sku.Restrictions) | Where-Object { $_.Type -eq "Location" }) {
            return
        }

        $vCpuText = ($Sku.Capabilities | Where-Object { $_.Name -eq "vCPUs" }    | Select-Object -First 1).Value
        $memText  = ($Sku.Capabilities | Where-Object { $_.Name -eq "MemoryGB" } | Select-Object -First 1).Value

        $vCPUs    = 0
        $memoryGB = [decimal]0

        $validCpu = [int]::TryParse([string]$vCpuText, [ref]$vCPUs)
        $validMem = [decimal]::TryParse(
            [string]$memText,
            [System.Globalization.NumberStyles]::Number,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$memoryGB
        )

        if (-not $validCpu -or -not $validMem) {
            return
        }

        [PSCustomObject]@{
            Name     = $Sku.Name
            vCPUs    = $vCPUs
            MemoryGB = $memoryGB
        }
    }

    # Retrieve all VM SKUs for the region once, with retry
    $skus = $null
    while ($true) {
        Write-Host ""
        Write-Host "Retrieving available VM sizes in $Location..." -ForegroundColor Cyan

        try {
            $skus = @(
                Get-AzComputeResourceSku -Location $Location -ErrorAction Stop |
                    Where-Object { $_.ResourceType -eq "virtualMachines" }
            )
            break
        }
        catch {
            Write-Warning "Unable to retrieve VM sizes."
            Write-Warning $_.Exception.Message

            $tryAgain = Read-YesNo -Prompt "Try retrieving VM sizes again?" -Default "Y"
            if (-not $tryAgain) {
                return $null
            }
        }
    }

    # Commonly used AVD sizes: at least 4 vCPU / 16 GB, not location-restricted
    $vmSizes = @(
        $skus |
            Where-Object { $_.Name -in $commonSkuNames } |
            ForEach-Object { ConvertTo-VmSizeInfo $_ } |
            Where-Object { $_.vCPUs -ge 4 -and $_.MemoryGB -ge 16 } |
            Sort-Object vCPUs, MemoryGB, Name -Unique
    )

    if ($vmSizes.Count -eq 0) {
        Write-Warning "No common AVD SKUs were found in $Location. You can still enter a size manually."
    }

    Write-Host ""
    Write-Host "Available Azure Image Builder VM sizes in ${Location}:" -ForegroundColor Cyan
    Write-Host ""

    for ($i = 0; $i -lt $vmSizes.Count; $i++) {
        $vm = $vmSizes[$i]
        Write-Host "[$($i + 1)] $($vm.Name) | $($vm.vCPUs) vCPU | $($vm.MemoryGB) GB RAM"
    }

    $customOption = $vmSizes.Count + 1
    Write-Host "[$customOption] Enter a different VM size"
    Write-Host ""

    do {
        $selection       = Read-Host "Select VM size"
        $selectionNumber = 0

        $validSelection = (
            [int]::TryParse($selection, [ref]$selectionNumber) -and
            $selectionNumber -ge 1 -and
            $selectionNumber -le $customOption
        )

        if (-not $validSelection) {
            Write-Warning "Enter a number between 1 and $customOption."
        }
    } until ($validSelection)

    if ($selectionNumber -eq $customOption) {
        while ($true) {
            $customName = (Read-Host "Enter your chosen VM size (e.g. Standard_D8s_v5)").Trim()

            $selectedVmSize = $skus |
                Where-Object { $_.Name -eq $customName } |
                ForEach-Object { ConvertTo-VmSizeInfo $_ } |
                Select-Object -First 1

            if ($selectedVmSize) {
                break
            }

            Write-Warning "'$customName' was not found in $Location, or is restricted for this subscription."

            $tryAgain = Read-YesNo -Prompt "Try another SKU?" -Default "Y"
            if (-not $tryAgain) {
                return $null
            }
        }
    }
    else {
        $selectedVmSize = $vmSizes[$selectionNumber - 1]
    }

    Write-Host ""
    Write-Host "Selected VM size: $($selectedVmSize.Name)" -ForegroundColor Green
    Write-Host "  vCPU:   $($selectedVmSize.vCPUs)"
    Write-Host "  Memory: $($selectedVmSize.MemoryGB) GB"

    return $selectedVmSize.Name
}

### Function for choosing image build location
function Select-BuildLocation {
    param (
        [Parameter(Mandatory)]
        [string]$DefaultLocation
    )

    Write-SectionHeader -Title "Choose Image build location. This is the location of the VM used to build the image."

    Write-Host ""
    Write-Host "Current resource group region: $DefaultLocation"
    Write-Host ""
    Write-Host "[1] Use resource group region: $DefaultLocation"
    Write-Host "[2] Select another build region"

    do {
        $choice = Read-Host "`nSelect an option"
    } until ($choice -in @("1", "2"))

    if ($choice -eq "1") {
        return $DefaultLocation.ToLower()
    }

    ## Moved this after the region selection so that user does not have to wait for region fetch if using default location
    Write-Host ""
    Write-Host "Retrieving Azure regions..." -ForegroundColor Cyan

    try {
        $availableLocations = @(
            Get-AzLocation -ErrorAction Stop |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_.Location)
                } |
                Sort-Object DisplayName
        )
    }
    catch {
        throw "Unable to retrieve Azure regions. $($_.Exception.Message)"
    }

    if ($availableLocations.Count -eq 0) {
        throw "No Azure regions were returned."
    }

    Write-Host ""
    Write-Host "Available build regions:" -ForegroundColor Cyan
    Write-Host ""

    for ($i = 0; $i -lt $availableLocations.Count; $i++) {
        $region = $availableLocations[$i]

        Write-Host "[$($i + 1)] $($region.DisplayName) [$($region.Location)]"
    }

    do {
        $selection = Read-Host "`nSelect build region"

        $selectionNumber = 0

        $validSelection = (
            [int]::TryParse($selection, [ref]$selectionNumber) -and
            $selectionNumber -ge 1 -and
            $selectionNumber -le $availableLocations.Count
        )

        if (-not $validSelection) {
            Write-Warning "Enter a number between 1 and $($availableLocations.Count)."
        }

    } until ($validSelection)

    return $availableLocations[$selectionNumber - 1].Location.ToLower()
}

## Allows multiple items of a list to be selected at once
function Read-MultiSelection {
    param (
        [Parameter(Mandatory)]
        [string]$Prompt,

        [Parameter(Mandatory)]
        [array]$Items
    )

    if ($Items.Count -eq 0) {
        return @()
    }

    Write-Host ""
    Write-Host $Prompt -ForegroundColor Cyan
    Write-Host ""

    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host "[$($i + 1)] $($Items[$i].DisplayName)"
    }

    Write-Host ""
    Write-Host "Enter numbers separated by commas, for example: 1,3,5"
    Write-Host "Press Enter to select none."

    while ($true) {
        $selection = Read-Host "`nSelect scripts"

        if ([string]::IsNullOrWhiteSpace($selection)) {
            return @()
        }

        $selectedNumbers = @()
        $validSelection = $true

        foreach ($entry in $selection.Split(",")) {
            $trimmedEntry = $entry.Trim()

            if ($trimmedEntry -notmatch '^\d+$') {
                $validSelection = $false
                break
            }

            $number = [int]$trimmedEntry

            if ($number -lt 1 -or $number -gt $Items.Count) {
                $validSelection = $false
                break
            }

            if ($number -notin $selectedNumbers) {
                $selectedNumbers += $number
            }
        }

        if (-not $validSelection) {
            Write-Warning "Enter valid numbers between 1 and $($Items.Count), separated by commas."
            continue
        }

        return @(
            foreach ($number in $selectedNumbers) {
                $Items[$number - 1]
            }
        )
    }
}


function ConvertTo-AibArgument {
    param (
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string[]]$Value
    )

    $escapedValues = @(
        foreach ($item in $Value) {
            "'$($item.Replace("'", "''"))'"
        }
    )

    return "-$Name $($escapedValues -join ',')"
}

# ------------------------------------------------------------
# Customizer builders
# ------------------------------------------------------------

function Format-AvdArgument {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value
    )

    $quoted = @($Value) | ForEach-Object { "'" + ([string]$_).Replace("'", "''") + "'" }
    "-$Name $($quoted -join ',')"
}


# Prompts for one script parameter and returns the formatted argument
# string (e.g. -Language 'English (United Kingdom)'), or $null if skipped.
# Returns the formatted argument string for one script parameter.
# - Parameters with a Default are applied silently (set Ask = $true on the
#   parameter to be prompted anyway, with the default pre-filled).
# - Parameters without a Default are prompted for. Mandatory ones must be
#   answered; optional ones can be skipped with a blank answer.
function Read-AvdScriptArgument {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Definition
    )

    $delimiter = if ($Definition.Delimiter) { $Definition.Delimiter } else { "," }
    $default   = $Definition.Default

    # Default exists and no prompt requested: just use it
    if ($default -and -not $Definition.Ask) {
        Write-Host "  Using default for -$($Definition.Name): $(@($default) -join $delimiter)" -ForegroundColor DarkGray
        return Format-AvdArgument -Name $Definition.Name -Value $default
    }

    $suffix = if ($default) { " [$(@($default) -join $delimiter)]" }
              elseif (-not $Definition.Mandatory) { " (blank to skip)" }
              else { "" }

    if ($Definition.Hint) {
        Write-Host ""
        Write-Host $Definition.Hint -ForegroundColor Cyan
    }

    while ($true) {
        $raw = Read-Host "$($Definition.Prompt)$suffix"

        if ([string]::IsNullOrWhiteSpace($raw)) {
            if ($default) {
                $value = $default
            }
            elseif (-not $Definition.Mandatory) {
                return $null
            }
            else {
                Write-Warning "A value is required."
                continue
            }
        }
        else {
            switch ($Definition.Kind) {
                "List" {
                    $value = @(
                        $raw.Split($delimiter) |
                            ForEach-Object { $_.Trim() } |
                            Where-Object { $_ }
                    )
                }
                "Int" {
                    $number = 0
                    if (-not [int]::TryParse($raw, [ref]$number)) {
                        Write-Warning "Enter a whole number."
                        continue
                    }
                    $value = $number
                }
                default { $value = $raw.Trim() }
            }
        }

        return Format-AvdArgument -Name $Definition.Name -Value $value
    }
}


function Get-CustomerCustomizer {
    $enabled = Read-YesNo `
        -Prompt "`nRun customer-specific PowerShell scripts during the image build?" `
        -Default "N"

    if (-not $enabled) {
        Write-Host "`nCustomer-specific scripts disabled." -ForegroundColor Yellow
        return
    }

    $defaultFile = Join-Path $PSScriptRoot "CustomScripts.json"
    $hasDefault  = Test-Path -LiteralPath $defaultFile -PathType Leaf

    $prompt = if ($hasDefault) { "`nEnter custom scripts JSON path [$defaultFile]" }
              else             { "`nEnter custom scripts JSON path" }

    $pathInput = (Read-Host $prompt).Trim().Trim('"')

    if ([string]::IsNullOrWhiteSpace($pathInput)) {
        if (-not $hasDefault) {
            throw "A custom scripts JSON file must be specified when customer scripts are enabled."
        }
        $pathInput = $defaultFile
    }

    if (-not (Test-Path -LiteralPath $pathInput -PathType Leaf)) {
        throw "Custom scripts JSON file not found: $pathInput"
    }

    $file = (Resolve-Path -LiteralPath $pathInput).Path

    try {
        $customizers = @(
            Get-Content -LiteralPath $file -Raw -ErrorAction Stop |
                ConvertFrom-Json -AsHashtable -ErrorAction Stop
        )
    }
    catch {
        throw "Failed to read custom scripts JSON file '$file'. $($_.Exception.Message)"
    }

    if ($customizers.Count -eq 0) {
        throw "Customer scripts are enabled, but '$file' contains no customizer objects."
    }

    for ($i = 0; $i -lt $customizers.Count; $i++) {
        foreach ($property in "type", "name") {
            if ([string]::IsNullOrWhiteSpace([string]$customizers[$i].$property)) {
                throw "Custom script entry $($i + 1) does not contain a '$property' property."
            }
        }
    }

    Write-Host ""
    Write-Host "Customer-specific scripts enabled." -ForegroundColor Green
    Write-Host "  File:  $file"
    Write-Host "  Count: $($customizers.Count)"

    $script:customScriptsFile = $file
    return $customizers
}


function Get-MicrosoftAvdCustomizer {
    $enabled = Read-YesNo `
        -Prompt "`nRun Microsoft AVD Custom Image Template scripts?" `
        -Default "Y"

    if (-not $enabled) {
        Write-Host "`nMicrosoft AVD scripts disabled." -ForegroundColor Yellow
        return
    }

    # Keep this pinned. Review and test a newer folder before changing it.
    $version = "CustomImageTemplateScripts_2024-03-27"
    $baseUri = "https://raw.githubusercontent.com/Azure/RDS-Templates/master/CustomImageTemplateScripts/$version"

    # Default the portal passes for the same scripts
    $vcRedist = "https://aka.ms/vs/17/release/vc_redist.x64.exe"

    # Verified     = parameters confirmed against a portal export
    # RestartAfter = the portal adds a restart after this script
    $catalog = @(
        [PSCustomObject]@{
            Key = "TeamsOptimization"; FileName = "TeamsOptimization.ps1"
            DisplayName = "Configure Microsoft Teams optimization"
            Verified = $true; RestartAfter = $false
            Parameters = @(
                @{ Name = "WebRTCInstaller";       Kind = "String"; Default = "https://aka.ms/msrdcwebrtcsvc/msi"; Prompt = "WebRTC redirector installer URL" }
                @{ Name = "VCRedistributableLink"; Kind = "String"; Default = $vcRedist; Prompt = "Visual C++ redistributable URL" }
                @{ Name = "TeamsBootStrapperUrl";  Kind = "String"; Default = "https://go.microsoft.com/fwlink/?linkid=2243204&clcid=0x409"; Prompt = "Teams bootstrapper URL" }
            )
        }
        [PSCustomObject]@{
            Key = "MultiMediaRedirection"; FileName = "MultiMediaRedirection.ps1"
            DisplayName = "Configure multimedia redirection"
            Verified = $true; RestartAfter = $false
            Parameters = @(
                @{ Name = "VCRedistributableLink"; Kind = "String"; Default = $vcRedist; Prompt = "Visual C++ redistributable URL" }
                @{ Name = "EnableEdge";   Kind = "String"; Default = "true"; Prompt = "Enable for Edge (true/false)" }
                @{ Name = "EnableChrome"; Kind = "String"; Default = "true"; Prompt = "Enable for Chrome (true/false)" }
            )
        }
        [PSCustomObject]@{
            Key = "WindowsOptimization"; FileName = "WindowsOptimization.ps1"
            DisplayName = "Windows optimizations for AVD"
            Verified = $true; RestartAfter = $true
            Parameters = @(@{
                Name = "Optimizations"; Kind = "List"; Delimiter = ","; Default = @("All")
                Prompt = "Enter categories separated by commas"
                Hint = "Categories: All, WindowsMediaPlayer, ScheduledTasks, DefaultUserSettings, Autologgers, Services, NetworkOptimizations, LGPO, DiskCleanup, Edge, RemoveLegacyIE, RemoveOneDrive"
            })
        }
        [PSCustomObject]@{
            Key = "FSLogix"; FileName = "FSLogix.ps1"
            DisplayName = "Install and configure FSLogix Profile Container"
            Verified = $true; RestartAfter = $false
            Parameters = @(
                @{ Name = "FSLogixInstaller"; Kind = "String"; Default = "https://aka.ms/fslogix_download"; Prompt = "FSLogix installer URL" }
                @{ Name = "VHDSize";          Kind = "String"; Default = "30000"; Prompt = "Profile VHD size (MB)" }
                @{ Name = "ProfilePath";      Kind = "String"; Mandatory = $true
                Prompt = "Enter the profile share UNC path"
                Hint = "Example: \\storageaccount.file.core.windows.net\profiles" }
            )
        }
        [PSCustomObject]@{
            Key = "SetDefaultLanguage"; FileName = "SetDefaultLang.ps1"
            DisplayName = "Set default language"
            Verified = $true; RestartAfter = $true
            Parameters = @(@{
                Name = "Language"; Kind = "String"; Mandatory = $true
                Prompt = "Enter the default language"
                Hint = "Example: English (United Kingdom)"
            })
        }
        [PSCustomObject]@{
            Key = "TimezoneRedirection"; FileName = "TimezoneRedirection.ps1"
            DisplayName = "Enable time zone redirection"
            Verified = $true; RestartAfter = $false; Parameters = @()
        }

        # ---- Not yet confirmed against a portal export: parameters may be wrong ----
        [PSCustomObject]@{
            Key = "InstallLanguagePacks"; FileName = "InstallLanguagePacks.ps1"
            DisplayName = "Install language packs"
            Verified = $false; RestartAfter = $true
            Parameters = @(@{
                Name = "LanguageList"; Kind = "List"; Delimiter = ";"; Mandatory = $true
                Prompt = "Enter language names separated by semicolons"
                Hint = "Example: English (United Kingdom);French (France);German (Germany)"
            })
        }
        [PSCustomObject]@{
            Key = "DisableStorageSense"; FileName = "DisableStorageSense.ps1"
            DisplayName = "Disable Storage Sense"
            Verified = $false; RestartAfter = $false; Parameters = @()
        }
        [PSCustomObject]@{
            Key = "RDPShortpath"; FileName = "RDPShortpath.ps1"
            DisplayName = "Configure RDP Shortpath for managed networks"
            Verified = $false; RestartAfter = $false; Parameters = @()
        }
        [PSCustomObject]@{
            Key = "ScreenCaptureProtection"; FileName = "ScreenCaptureProtection.ps1"
            DisplayName = "Configure screen capture protection"
            Verified = $false; RestartAfter = $false; Parameters = @()
        }
        [PSCustomObject]@{
            Key = "FSLogixKerberos"; FileName = "FSLogixKerberos.ps1"
            DisplayName = "Configure FSLogix Kerberos support"
            Verified = $false; RestartAfter = $false; Parameters = @()
        }
        [PSCustomObject]@{
            Key = "ConfigureSessionTimeouts"; FileName = "ConfigureSessionTimeoutsV2.ps1"
            DisplayName = "Configure AVD session timeouts"
            Verified = $false; RestartAfter = $false
            Parameters = @(
                @{ Name = "MaxDisconnectionTime";     Kind = "Int"; Prompt = "Max disconnection time in minutes, e.g. 60" }
                @{ Name = "MaxIdleTime";              Kind = "Int"; Prompt = "Max idle time in minutes, e.g. 30" }
                @{ Name = "MaxConnectionTime";        Kind = "Int"; Prompt = "Max connection time in minutes, e.g. 480" }
                @{ Name = "RemoteAppLogoffTimeLimit"; Kind = "Int"; Prompt = "RemoteApp logoff time limit in minutes, e.g. 15" }
            )
        }
        [PSCustomObject]@{
            Key = "RemoveAppxPackages"; FileName = "RemoveAppxPackages.ps1"
            DisplayName = "Remove selected AppX packages"
            Verified = $false; RestartAfter = $false
            Parameters = @(@{
                Name = "AppxPackages"; Kind = "List"; Delimiter = ";"; Mandatory = $true
                Prompt = "Enter AppX package names separated by semicolons"
                Hint = "Example: Microsoft.BingWeather;Microsoft.ZuneMusic"
            })
        }
    )

    $selected = @(
        Read-MultiSelection `
            -Prompt "Select Microsoft AVD scripts to run:" `
            -Items $catalog
    )

    foreach ($avdScript in $selected) {
        if (-not $avdScript.Verified) {
            Write-Warning "$($avdScript.DisplayName): parameters are not verified against the pinned script."
        }

        $scriptUri = "$baseUri/$($avdScript.FileName)"

        $arguments = @(
            $avdScript.Parameters |
                ForEach-Object { Read-AvdScriptArgument -Definition $_ } |
                Where-Object { $_ }
        )

        if ($arguments.Count -gt 0) {
            # Same pattern as the portal: download the script, then run it
            # from an inline command with its parameters.
            $localPath = "C:\AVDImage\$($avdScript.FileName)"

            [ordered]@{
                type        = "File"
                name        = "MicrosoftAVD-$($avdScript.Key)-download"
                sourceUri   = $scriptUri
                destination = $localPath
            }

            [ordered]@{
                type        = "PowerShell"
                name        = "MicrosoftAVD-$($avdScript.Key)-parameter"
                runElevated = $true
                runAsSystem = $true
                inline      = @("$localPath $($arguments -join ' ')")
            }
        }
        else {
            [ordered]@{
                type        = "PowerShell"
                name        = "MicrosoftAVD-$($avdScript.Key)"
                runElevated = $true
                runAsSystem = $true
                scriptUri   = $scriptUri
            }
        }

        if ($avdScript.RestartAfter) {
            [ordered]@{
                type           = "WindowsRestart"
                name           = "MicrosoftAVD-$($avdScript.Key)-restart"
                restartTimeout = "5m"
            }
        }
    }

    Write-Host ""
    Write-Host "Microsoft AVD scripts selected:" -ForegroundColor Green
    if ($selected.Count -eq 0) { Write-Host "  None" }
    else { $selected | ForEach-Object { Write-Host "  - $($_.DisplayName)" } }
}


function Get-WindowsUpdateCustomizer {
    $enabled = Read-YesNo `
        -Prompt "`nInstall Windows Updates during the image build?" `
        -Default "Y"

    if (-not $enabled) {
        Write-Host "`nWindows Update disabled." -ForegroundColor Yellow
        return
    }

    $limit = Read-IntegerWithDefault `
        -Prompt "Maximum number of Windows Updates to install" `
        -DefaultValue 40 `
        -MinimumValue 1

    $excludePreview = Read-YesNo -Prompt "Exclude Preview updates?" -Default "Y"

    $filters = @()
    if ($excludePreview) { $filters += "exclude:`$_.Title -like '*Preview*'" }
    $filters += "include:`$true"

    Write-Host ""
    Write-Host "Windows Update enabled." -ForegroundColor Green
    Write-Host "  Update limit:            $limit"
    Write-Host "  Exclude Preview updates: $excludePreview"

    $script:windowsUpdateLimit = $limit

    [ordered]@{
        type           = "WindowsUpdate"
        name           = "InstallWindowsUpdates"
        searchCriteria = "IsInstalled=0"
        filters        = $filters
        updateLimit    = [int]$limit
    }
}


function Get-RestartCustomizer {
    $enabled = Read-YesNo `
        -Prompt "`nRestart Windows after customisation?" `
        -Default "Y"

    if (-not $enabled) {
        Write-Host "`nFinal Windows restart disabled." -ForegroundColor Yellow
        return
    }

    Write-Host "`nFinal Windows restart enabled." -ForegroundColor Green

    [ordered]@{
        type           = "WindowsRestart"
        name           = "FinalWindowsRestart"
        restartTimeout = "15m"
    }
}

# ------------------------------------------------------------
# Check required Azure PowerShell commands
# ------------------------------------------------------------

$requiredCommands = @(
    "Connect-AzAccount"
    "Get-AzContext"
    "Get-AzComputeResourceSku"
    "Get-AzLocation"
    "Get-AzSubscription"
    "Set-AzContext"
    "Get-AzResourceGroup"
    "Get-AzUserAssignedIdentity"
    "Get-AzGallery"
    "Get-AzGalleryImageDefinition"
    "Get-AzGalleryImageVersion"
    "Test-AzResourceGroupDeployment"
    "New-AzResourceGroupDeployment"
)

foreach ($command in $requiredCommands) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Required Azure PowerShell command is not available: $command"
    }
}


# ------------------------------------------------------------
# Locate Bicep template
# ------------------------------------------------------------

Write-SectionHeader -Title "Locating Bicep file..."

## If the Bicep file is renamed, this must be edited ##
$templateFile = Join-Path $PSScriptRoot "AIB-ImageTemplate-Deploy.bicep"

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

$selectedSubscription = Select-NumberedItem `
    -Prompt "Select the Azure subscription:" `
    -Items $subscriptions `
    -DisplayProperty {
        param($item)

        "$($item.Name) [$($item.Id)]"
    }

Set-AzContext `
    -SubscriptionId $selectedSubscription.Id `
    -ErrorAction Stop |
    Out-Null

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
# Deployment resource group selection
# ------------------------------------------------------------

Write-SectionHeader -Title "Deployment Resource Group selection:"

$resourceGroups = @(
    Get-AzResourceGroup -ErrorAction Stop |
        Sort-Object ResourceGroupName
)

$selectedResourceGroup = Select-NumberedItem `
    -Prompt "Select the resource group containing the AIB components: (UMI, Storage Acc, etc)" `
    -Items $resourceGroups `
    -DisplayProperty {
        param($item)

        "$($item.ResourceGroupName) [$($item.Location)]"
    }

$resourceGroupName = $selectedResourceGroup.ResourceGroupName
$location = $selectedResourceGroup.Location

Write-Host ""
Write-Host "Deployment resource group:" -ForegroundColor Green
Write-Host "  Name:     $resourceGroupName"
Write-Host "  Location: $location"

# ------------------------------------------------------------
# Azure Image Builder build location
#
# The image template and temporary build VM run in this region.
# It does not have to match the resource-group location.
# ------------------------------------------------------------

$buildLocation = Select-BuildLocation `
    -DefaultLocation $location

Write-Host ""
Write-Host "The image template and temporary build VM run in this region. It does not have to match the resource-group location."
Write-Host "Azure Image Builder location:" -ForegroundColor Green
Write-Host "  Resource group region: $location"
Write-Host "  AIB build region:      $buildLocation"


# ------------------------------------------------------------
# User-assigned managed identity selection
# ------------------------------------------------------------

$managedIdentities = @(
    Get-AzUserAssignedIdentity `
        -ResourceGroupName $resourceGroupName `
        -ErrorAction Stop |
        Sort-Object Name
)

$selectedManagedIdentity = Select-NumberedItem `
    -Prompt "Select the Azure Image Builder user-assigned managed identity:" `
    -Items $managedIdentities `
    -DisplayProperty {
        param($item)

        "$($item.Name) [$($item.Location)]"
    }

$imageBuilderIdentityName = $selectedManagedIdentity.Name


# ------------------------------------------------------------
# Target gallery selection
# ------------------------------------------------------------

$targetGalleries = @(
    Get-AzGallery `
        -ResourceGroupName $resourceGroupName `
        -ErrorAction Stop |
        Sort-Object Name
)

$selectedTargetGallery = Select-NumberedItem `
    -Prompt "Select the TARGET Azure Compute Gallery:" `
    -Items $targetGalleries `
    -DisplayProperty {
        param($item)

        "$($item.Name) [$($item.Location)]"
    }

$imageGalleryName = $selectedTargetGallery.Name


# ------------------------------------------------------------
# Target image definition selection
# ------------------------------------------------------------

$targetImageDefinitions = @(
    Get-AzGalleryImageDefinition `
        -ResourceGroupName $resourceGroupName `
        -GalleryName $imageGalleryName `
        -ErrorAction Stop |
        Sort-Object Name
)

$selectedTargetImageDefinition = Select-NumberedItem `
    -Prompt "Select the TARGET image definition:" `
    -Items $targetImageDefinitions `
    -DisplayProperty {
        param($item)

        $details = @(
            $item.Name
            $item.OsType
            $item.OsState
            $item.HyperVGeneration
        ) | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_)
        }

        $details -join " | "
    }

$imageDefinitionName = $selectedTargetImageDefinition.Name


# ------------------------------------------------------------
# Source image selection
# ------------------------------------------------------------

Write-SectionHeader -Title "Source Image Selection:"

Write-Host ""
Write-Host "Select the source image type:" -ForegroundColor Cyan
Write-Host ""
Write-Host "[1] Azure Marketplace image"
Write-Host "[2] Existing Azure Compute Gallery image version"

do {
    $sourceChoice = Read-Host "`nSelect an option"
} until ($sourceChoice -in @("1", "2"))


if ($sourceChoice -eq "1") {

    # --------------------------------------------------------
    # Marketplace source
    # --------------------------------------------------------

    Write-SectionHeader -Title "Marketplace Image selected:"

    $sourceType = "PlatformImage"
    $sourceImageVersionId = ""

    Write-Host ""
    Write-Host "Using Azure Marketplace image as source." -ForegroundColor Green

    $sourcePublisher = Read-ValueWithDefault `
        -Prompt "Marketplace publisher" `
        -DefaultValue "MicrosoftWindowsDesktop"

    $sourceOffer = Read-ValueWithDefault `
        -Prompt "Marketplace offer" `
        -DefaultValue "office-365"

    $sourceSku = Read-ValueWithDefault `
        -Prompt "Marketplace SKU" `
        -DefaultValue "win11-25h2-avd-m365"

    $sourceVersion = Read-ValueWithDefault `
        -Prompt "Marketplace version" `
        -DefaultValue "latest"
}
else {

    # --------------------------------------------------------
    # Existing Compute Gallery source
    # --------------------------------------------------------

    Write-SectionHeader -Title "Existing Compute Gallery Image selected:"

    $sourceType = "SharedImageVersion"

    $sourcePublisher = ""
    $sourceOffer = ""
    $sourceSku = ""
    $sourceVersion = ""

    $allGalleries = @(
        Get-AzGallery -ErrorAction Stop
    )

    if ($allGalleries.Count -eq 0) {
        throw "No Azure Compute Galleries were found in the selected subscription."
    }

    # --------------------------------------------------------
    # Source gallery resource group
    # --------------------------------------------------------

    $galleryResourceGroups = @(
        $allGalleries |
            Select-Object -ExpandProperty ResourceGroupName -Unique |
            Sort-Object
    )

    $sourceGalleryResourceGroupName = Select-NumberedItem `
        -Prompt "Select the resource group containing the SOURCE gallery image:" `
        -Items $galleryResourceGroups `
        -DisplayProperty {
            param($item)
            $item
        }

    # --------------------------------------------------------
    # Source gallery
    # --------------------------------------------------------

    $sourceGalleries = @(
        $allGalleries |
            Where-Object {
                $_.ResourceGroupName -eq $sourceGalleryResourceGroupName
            } |
            Sort-Object Name
    )

    $selectedSourceGallery = Select-NumberedItem `
        -Prompt "Select the SOURCE Azure Compute Gallery:" `
        -Items $sourceGalleries `
        -DisplayProperty {
            param($item)
            "$($item.Name) [$($item.Location)]"
        }

    $sourceGalleryName = $selectedSourceGallery.Name

    # --------------------------------------------------------
    # Source image definition
    # --------------------------------------------------------

    $sourceImageDefinitions = @(
        Get-AzGalleryImageDefinition `
            -ResourceGroupName $sourceGalleryResourceGroupName `
            -GalleryName $sourceGalleryName `
            -ErrorAction Stop |
            Sort-Object Name
    )

    $selectedSourceImageDefinition = Select-NumberedItem `
        -Prompt "Select the SOURCE image definition:" `
        -Items $sourceImageDefinitions `
        -DisplayProperty {
            param($item)
            $item.Name
        }

    $sourceImageDefinitionName = $selectedSourceImageDefinition.Name

    # --------------------------------------------------------
    # Source image version
    # --------------------------------------------------------

    $sourceImageVersions = @(
        Get-AzGalleryImageVersion `
            -ResourceGroupName $sourceGalleryResourceGroupName `
            -GalleryName $sourceGalleryName `
            -GalleryImageDefinitionName $sourceImageDefinitionName `
            -ErrorAction Stop |
            Sort-Object Name -Descending
    )

    $selectedSourceImageVersion = Select-NumberedItem `
        -Prompt "Select the SOURCE image version:" `
        -Items $sourceImageVersions `
        -DisplayProperty {
            param($item)
            $item.Name
        }

    $sourceImageVersionId = $selectedSourceImageVersion.Id
}


# ------------------------------------------------------------
# Image template settings
# ------------------------------------------------------------

Write-SectionHeader -Title "Image Template settings:"

$defaultImageTemplateName = "$customerCode-avd-win11-aib"
$defaultRunOutputName = "$customerCode-avd-win11"

$imageTemplateName = Read-ValueWithDefault `
    -Prompt "Enter image template name" `
    -DefaultValue $defaultImageTemplateName

$runOutputName = Read-ValueWithDefault `
    -Prompt "Enter run output name" `
    -DefaultValue $defaultRunOutputName

$vmSize = Select-VMSize -Location $buildLocation

if ([string]::IsNullOrWhiteSpace($vmSize)) {
    throw "A VM size could not be selected."
}

$osDiskSizeGB = Read-IntegerWithDefault `
    -Prompt "Enter OS disk size in GB" `
    -DefaultValue 127 `
    -MinimumValue 64

$buildTimeoutInMinutes = Read-IntegerWithDefault `
    -Prompt "Enter build timeout in minutes" `
    -DefaultValue 240 `
    -MinimumValue 30


# ------------------------------------------------------------
# Replication regions
# ------------------------------------------------------------

$replicationRegionInput = Read-Host `
    "`nEnter replication regions separated by commas [$location]"

if ([string]::IsNullOrWhiteSpace($replicationRegionInput)) {
    $replicationRegions = @($location.ToLower())
}
else {
    $replicationRegions = @(
        $replicationRegionInput.Split(",") |
            ForEach-Object {
                $_.Trim().ToLower()
            } |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_)
            } |
            Select-Object -Unique
    )
}

if ($replicationRegions.Count -eq 0) {
    throw "At least one replication region must be specified."
}


# ------------------------------------------------------------
# Build ordered AIB customizer list
#
# Execution order:
#   1. Customer-specific scripts
#   2. Microsoft AVD scripts
#   3. Windows Update
#   4. Final Windows restart
# ------------------------------------------------------------

$customScriptsFile  = $null
$windowsUpdateLimit = $null

$customScripts = @(
    Get-CustomerCustomizer
    Get-MicrosoftAvdCustomizer
    Get-WindowsUpdateCustomizer
    Get-RestartCustomizer
)

Write-Host ""
Write-Host "Customisation summary" -ForegroundColor Cyan
Write-Host "  Total customizers:     $($customScripts.Count)"
if ($customScriptsFile)  { Write-Host "  Customer scripts file: $customScriptsFile" }
if ($windowsUpdateLimit) { Write-Host "  Windows Update limit:  $windowsUpdateLimit" }

if ($customScripts.Count -gt 0) {
    Write-Host ""
    Write-Host "  Execution order:"
    for ($i = 0; $i -lt $customScripts.Count; $i++) {
        Write-Host "    $($i + 1). $($customScripts[$i].name) [$($customScripts[$i].type)]"
    }
}


# ------------------------------------------------------------
# Deployment summary
# ------------------------------------------------------------

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "Azure Image Builder template deployment summary" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

Write-Host ""
Write-Host "Subscription"
Write-Host "  Name:                   $($selectedSubscription.Name)"
Write-Host "  ID:                     $($selectedSubscription.Id)"

Write-Host ""
Write-Host "Deployment"
Write-Host "  Resource group:         $resourceGroupName"
Write-Host "  Resource group location:$location"
Write-Host "  AIB Build region:       $buildLocation"
Write-Host "  Customer code:          $customerCode"
Write-Host "  Image template:         $imageTemplateName"
Write-Host "  Run output name:        $runOutputName"

Write-Host ""
Write-Host "Azure Image Builder"
Write-Host "  Managed identity:       $imageBuilderIdentityName"
Write-Host "  Build VM size:          $vmSize"
Write-Host "  OS disk size:           $osDiskSizeGB GB"
Write-Host "  Build timeout:          $buildTimeoutInMinutes minutes"

Write-Host ""
Write-Host "Source image"
Write-Host "  Resource group:         $sourceGalleryResourceGroupName"
Write-Host "  Gallery:                $sourceGalleryName"
Write-Host "  Image definition:       $sourceImageDefinitionName"
Write-Host "  Version:                $($selectedSourceImageVersion.Name)"
Write-Host "  Version ID:             $sourceImageVersionId"

Write-Host ""
Write-Host "Target image"
Write-Host "  Gallery:                $imageGalleryName"
Write-Host "  Image definition:       $imageDefinitionName"
Write-Host "  Replication regions:    $($replicationRegions -join ', ')"

Write-Host ""
Write-Host "Customisation"
Write-Host "  Total customizers:      $($customScripts.Count)"

if ($customScriptsFile) {
    Write-Host "  Custom scripts file:    $customScriptsFile"
}

foreach ($customizer in $customScripts) {
    Write-Host "    - $($customizer.name) [$($customizer.type)]"
}

Write-Host ""
Write-Host "This deployment creates or updates the image template."
Write-Host "The image build will only start if selected after deployment."
Write-Host ""


# ------------------------------------------------------------
# Deployment confirmation
# ------------------------------------------------------------

Write-SectionHeader -Title "Deployment Confirmation:"

$continueDeployment = Read-YesNo `
    -Prompt "Continue with template validation and deployment?" `
    -Default "N"

if (-not $continueDeployment) {
    Write-Host ""
    Write-Host "Deployment cancelled." -ForegroundColor Yellow
    return
}


# ------------------------------------------------------------
# Deployment parameters
# ------------------------------------------------------------

$deploymentParameters = @{
    ResourceGroupName        = $resourceGroupName
    TemplateFile             = $templateFile
    customerCode             = $customerCode
    buildLocation            = $buildLocation
    imageBuilderIdentityName = $imageBuilderIdentityName
    imageGalleryName         = $imageGalleryName
    imageDefinitionName      = $imageDefinitionName
    imageTemplateName        = $imageTemplateName
    runOutputName            = $runOutputName
    replicationRegions       = $replicationRegions
    vmSize                   = $vmSize
    osDiskSizeGB             = $osDiskSizeGB
    buildTimeoutInMinutes    = $buildTimeoutInMinutes
    sourceType               = $sourceType
    sourceImageVersionId     = $sourceImageVersionId
    sourcePublisher          = $sourcePublisher
    sourceOffer              = $sourceOffer
    sourceSku                = $sourceSku
    sourceVersion            = $sourceVersion
    customScripts            = $customScripts
    ErrorAction              = "Stop"
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
# Deploy image template
# ------------------------------------------------------------
Write-SectionHeader -Title "Deploying Image Template:"

Write-Host ""
Write-Host "Creating or updating Azure Image Builder template..." -ForegroundColor Cyan

$deploymentName = "aib-template-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

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


# ------------------------------------------------------------
# Optional image build start
# ------------------------------------------------------------

Write-SectionHeader -Title "Template creation complete. Start Image build?"

Write-Host ""

$startBuild = Read-YesNo `
    -Prompt "Start the Azure Image Builder build now?" `
    -Default "N"

if ($startBuild) {

    # Make sure the Az.ImageBuilder module is available first
    if (-not (Get-Command "Start-AzImageBuilderTemplate" -ErrorAction SilentlyContinue)) {

        Write-Warning "Start-AzImageBuilderTemplate is not currently available."

        $installModule = Read-YesNo `
            -Prompt "Install/import the Az.ImageBuilder module now?" `
            -Default "Y"

        if (-not $installModule) {
            Write-Host ""
            Write-Host "The image template was deployed successfully." -ForegroundColor Green
            Write-Host "The image build has NOT been started." -ForegroundColor Yellow
            return
        }

        try {
            Write-Host ""
            Write-Host "Installing Az.ImageBuilder..." -ForegroundColor Cyan

            Install-Module `
                -Name Az.ImageBuilder `
                -Scope CurrentUser `
                -Force `
                -AllowClobber `
                -ErrorAction Stop

            Import-Module Az.ImageBuilder -Force -ErrorAction Stop

            Write-Host "Az.ImageBuilder loaded successfully." -ForegroundColor Green
        }
        catch {
            Write-Warning "Unable to install/import Az.ImageBuilder:"
            Write-Warning $_.Exception.Message

            Write-Host ""
            Write-Host "The image template was still deployed successfully." -ForegroundColor Green
            Write-Host "The image build has NOT been started." -ForegroundColor Yellow
            return
        }
    }

    Write-Host ""
    Write-Host "Starting image build..." -ForegroundColor Cyan

    Start-AzImageBuilderTemplate `
        -ResourceGroupName $resourceGroupName `
        -Name $imageTemplateName `
        -NoWait `
        -ErrorAction Stop

    Write-Host ""
    Write-Host "Image build request submitted successfully." -ForegroundColor Green
    Write-Host "The build is running asynchronously because -NoWait was used."
}
else {
    Write-Host ""
    Write-Host "Image template created. Image build was not started." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "To start it later, run:"
    Write-Host ""
    Write-Host "Start-AzImageBuilderTemplate ``"
    Write-Host "    -ResourceGroupName '$resourceGroupName' ``"
    Write-Host "    -Name '$imageTemplateName' ``"
    Write-Host "    -NoWait"
}