<#
.SYNOPSIS
    Set-VCFHostCPU v1.1
    Sets CPU EoL custom attributes on ESXi Host objects in vCenter Server.
    CPU EoL data is loaded from a versioned local JSON file (cpu-eol-db.json).

.DESCRIPTION
    1. Loads cpu-eol-db.json and builds EoL match patterns for the target VCF version.
    2. Connects to vCenter Server using PowerCLI.
    3. Ensures all required Custom Attribute keys exist on HostSystem objects
       (creates them automatically if missing).
    4. Reads the CPU model from each ESXi host via vCenter.
    5. Matches the CPU model against the EoL database
       (Discontinued takes priority over Deprecated).
    6. Writes 6 custom attributes per host:
         CPU_Status    -> "Supported" / "Deprecated" / "Discontinued"
         CPU_Code      -> "0" / "1" / "2"
         CPU_Codename  -> e.g. "Broadwell-EP"
         CPU_Series    -> e.g. "E5-2680 v4"
         CPU_VCF_Version   -> VCF version evaluated against (e.g. "9.x")
         CPU_KB_Reference  -> Broadcom KB article URL

    Custom Attributes can be deleted at any time via:
      vCenter UI -> Menu -> Tags & Custom Attributes -> Custom Attributes -> Delete
    Or via PowerCLI:
      Get-CustomAttribute -Name "CPU_EoL_Status" -TargetType VMHost | Remove-CustomAttribute -Confirm:$false

.PARAMETER vCenterHost
    FQDN or IP of your vCenter Server (e.g. vcenter.lab.local)

.PARAMETER Credential
    PSCredential for a vCenter user with write access to host annotations

.PARAMETER VCFVersion
    VCF version to evaluate against. Must match a key in cpu-eol-db.json.
    Defaults to "9.x". Use "10.x" to pre-check before an upgrade.

.PARAMETER SkipCertificateCheck
    Bypasses TLS certificate validation (useful in lab environments)

.EXAMPLE
    $cred = Get-Credential
    .\Set-VCFHostCPU_1.ps1 -vCenterHost "vcenter.lab.local" -Credential $cred -SkipCertificateCheck

.EXAMPLE
    .\Set-VCFHostCPU_1.ps1 -vCenterHost "vcenter.lab.local" -Credential $cred -VCFVersion "10.x" -SkipCertificateCheck

.NOTES
    Requires VMware PowerCLI module:
      Install-Module VMware.PowerCLI -Scope CurrentUser
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string]$vCenterHost,

    [Parameter(Mandatory)]
    [System.Management.Automation.PSCredential]$Credential,

    [string]$VCFVersion = "9.x",

    [switch]$SkipCertificateCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION — Edit here to rename or extend custom attributes
# ─────────────────────────────────────────────────────────────────────────────
$scriptVersion = "1.1"
$KB_URL        = "https://knowledge.broadcom.com/external/article/318697"

# Custom Attribute key names written to each VMHost in vCenter.
# Auto-created on first run if they do not already exist.
# To delete: vCenter UI -> Tags & Custom Attributes -> Custom Attributes -> Delete
$attr_Status      = "CPU_Status"
$attr_Code        = "CPU_Code"
$attr_Codename    = "CPU_Codename"
$attr_Series      = "CPU_Series"
$attr_VCFVersion  = "CPU_VCF_Version"
$attr_KBReference = "CPU_KB_Reference"

# Icons — using ConvertFromUtf32 for full emoji codepoint support
function icon { param([int]$cp) [System.Char]::ConvertFromUtf32($cp) }

$icon_ok      = icon 0x2705   # ✅
$icon_warn    = icon 0x26A0   # ⚠
$icon_fail    = icon 0x274C   # ❌
$icon_info    = icon 0x2139   # ℹ
$icon_db      = icon 0x1F4C2  # 📂
$icon_connect = icon 0x1F511  # 🔑
$icon_scan    = icon 0x1F50D  # 🔍
$icon_write   = icon 0x1F4BE  # 💾
$icon_summary = icon 0x1F4CA  # 📊
$icon_done    = icon 0x1F3C1  # 🏁
$icon_red     = icon 0x1F534  # 🔴
$icon_yellow  = icon 0x1F7E1  # 🟡
$icon_green   = icon 0x1F7E2  # 🟢
$icon_attr    = icon 0x1F3F7  # 🏷
$icon_link    = icon 0x1F517  # 🔗
$icon_cloud   = icon 0x2601   # ☁
# ─────────────────────────────────────────────────────────────────────────────

function Write-SectionHeader {
    param([string]$Title, [string]$Icon)
    Write-Host ""
    Write-Host ("─" * 80) -ForegroundColor DarkGray
    Write-Host "  $Icon  $Title" -ForegroundColor White
    Write-Host ("─" * 80) -ForegroundColor DarkGray
}

function Write-Banner {
    param([string]$Version)
    Write-Host ""
    Write-Host ("═" * 80) -ForegroundColor Cyan
    Write-Host "  $icon_cloud  VCF Host CPU Lifecycle Attribute Tagger  |  v$Version" -ForegroundColor Cyan
    Write-Host "  $icon_link  $KB_URL" -ForegroundColor DarkGray
    Write-Host ("═" * 80) -ForegroundColor Cyan
}

# ─── BANNER ───────────────────────────────────────────────────────────────────
Write-Banner -Version $scriptVersion

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1 — Load EoL Database
# ─────────────────────────────────────────────────────────────────────────────
Write-SectionHeader -Title "STEP 1 / 4   Loading Lifecycle Database" -Icon $icon_db

$jsonPath = Join-Path $PSScriptRoot "cpu-eol-db.json"
if (-not (Test-Path $jsonPath)) {
    Write-Host "  $icon_fail  cpu-eol-db.json not found in $PSScriptRoot" -ForegroundColor Red
    exit 1
}

$db = Get-Content $jsonPath -Raw | ConvertFrom-Json

$availableVersions = ($db.versions | Get-Member -MemberType NoteProperty).Name
if ($VCFVersion -notin $availableVersions) {
    Write-Host "  $icon_fail  VCF version '$VCFVersion' not found in cpu-eol-db.json." -ForegroundColor Red
    Write-Host "             Available: $($availableVersions -join ', ')" -ForegroundColor Red
    exit 1
}

$versionData    = $db.versions.$VCFVersion
$CpuEolDatabase = @()

foreach ($entry in $versionData.discontinued) {
    foreach ($token in @($entry.series, $entry.codename)) {
        if ($token -and $token.Trim().Length -gt 2) {
            $CpuEolDatabase += [PSCustomObject]@{
                Pattern  = [regex]::Escape($token.Trim())
                Series   = $entry.series
                Codename = $entry.codename
                Status   = "Discontinued"
                Code     = 2
            }
        }
    }
}

foreach ($entry in $versionData.deprecated) {
    foreach ($token in @($entry.series, $entry.codename)) {
        if ($token -and $token.Trim().Length -gt 2) {
            $CpuEolDatabase += [PSCustomObject]@{
                Pattern  = [regex]::Escape($token.Trim())
                Series   = $entry.series
                Codename = $entry.codename
                Status   = "Deprecated"
                Code     = 1
            }
        }
    }
}

Write-Host "  $icon_ok  Source       : $($db.source)" -ForegroundColor Green
Write-Host "  $icon_ok  Last Updated : $($db.lastUpdated)" -ForegroundColor Green
Write-Host "  $icon_ok  VCF Version  : $VCFVersion" -ForegroundColor Green
Write-Host "  $icon_ok  Patterns     : $($CpuEolDatabase.Count) total loaded" -ForegroundColor Green
Write-Host "  $icon_red  Discontinued : $(($CpuEolDatabase | Where-Object Code -eq 2).Count) patterns" -ForegroundColor Red
Write-Host "  $icon_yellow  Deprecated   : $(($CpuEolDatabase | Where-Object Code -eq 1).Count) patterns" -ForegroundColor Yellow
Write-Host ""
Write-Host "  $icon_attr  Custom attributes to be written:" -ForegroundColor Cyan
foreach ($a in @($attr_Status, $attr_Code, $attr_Codename, $attr_Series, $attr_VCFVersion, $attr_KBReference)) {
    Write-Host "       $icon_info  $a" -ForegroundColor DarkGray
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2 — Connect to vCenter
# ─────────────────────────────────────────────────────────────────────────────
Write-SectionHeader -Title "STEP 2 / 4   Connecting to vCenter Server" -Icon $icon_connect

$null = Set-PowerCLIConfiguration -Scope Session -ParticipateInCEIP $false -Confirm:$false -ErrorAction SilentlyContinue

if ($SkipCertificateCheck) {
    $null = Set-PowerCLIConfiguration -Scope Session -InvalidCertificateAction Ignore -Confirm:$false
}

try {
    $null = Connect-VIServer -Server $vCenterHost -Credential $Credential -ErrorAction Stop
    Write-Host "  $icon_ok  Connected to : $vCenterHost" -ForegroundColor Green
    Write-Host "  $icon_ok  Connected as : $($Credential.UserName)" -ForegroundColor Green
} catch {
    Write-Host "  $icon_fail  Failed to connect to vCenter: $_" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "  $icon_attr  Verifying custom attribute definitions..." -ForegroundColor Cyan
Write-Host ""

foreach ($attrName in @($attr_Status, $attr_Code, $attr_Codename, $attr_Series, $attr_VCFVersion, $attr_KBReference)) {
    $existing = Get-CustomAttribute -Name $attrName -TargetType VMHost -ErrorAction SilentlyContinue
    if (-not $existing) {
        $null = New-CustomAttribute -Name $attrName -TargetType VMHost
        Write-Host "  $icon_warn  Created new  : $attrName" -ForegroundColor Yellow
    } else {
        Write-Host "  $icon_ok  Exists       : $attrName" -ForegroundColor Green
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3 — Evaluate CPU EoL
# ─────────────────────────────────────────────────────────────────────────────
Write-SectionHeader -Title "STEP 3 / 4   Analyzing ESXi Host Hardware" -Icon $icon_scan

$allHosts = Get-VMHost | Sort-Object Name
Write-Host "  $icon_ok  Found $($allHosts.Count) host(s) to evaluate." -ForegroundColor Green
Write-Host ""

$results = @()

foreach ($vmHost in $allHosts) {
    $cpuModel = $vmHost.ExtensionData.Summary.Hardware.CpuModel
    if (-not $cpuModel) { $cpuModel = "Unknown" }

    # EoL correlation -- highest severity wins
    $matchedStatus   = "Supported"
    $matchedCode     = 0
    $matchedSeries   = "Current Generation"
    $matchedCodename = "No EoL concern for VCF $VCFVersion"

    if ($cpuModel -ne "Unknown") {
        foreach ($entry in $CpuEolDatabase) {
            if ($cpuModel -match $entry.Pattern) {
                if ($entry.Code -gt $matchedCode) {
                    $matchedStatus   = $entry.Status
                    $matchedCode     = $entry.Code
                    $matchedSeries   = $entry.Series
                    $matchedCodename = $entry.Codename
                }
            }
        }
    }

    $results += [PSCustomObject]@{
        VMHost          = $vmHost
        HostName        = $vmHost.Name
        CpuModel        = $cpuModel
        MatchedSeries   = $matchedSeries
        MatchedCodename = $matchedCodename
        Status          = $matchedStatus
        Code            = $matchedCode
    }

    $color      = switch ($matchedCode) { 2 { "Red" } 1 { "Yellow" } default { "Green" } }
    $statusIcon = switch ($matchedCode) { 2 { $icon_red } 1 { $icon_yellow } default { $icon_green } }
    $detail     = if ($matchedCode -gt 0) { "  [$matchedCodename / $matchedSeries]" } else { "" }

    Write-Host "  $statusIcon " -NoNewline
    Write-Host "$($vmHost.Name.PadRight(30)) " -NoNewline -ForegroundColor Cyan
    Write-Host "| CPU: " -NoNewline -ForegroundColor DarkGray
    Write-Host "$($cpuModel.PadRight(42)) " -NoNewline -ForegroundColor White
    Write-Host "-> [$matchedStatus]$detail" -ForegroundColor $color
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4 — Write Custom Attributes
# ─────────────────────────────────────────────────────────────────────────────
Write-SectionHeader -Title "STEP 4 / 4   Writing Custom Attributes to vCenter" -Icon $icon_write
Write-Host ""

$successCount = 0

foreach ($result in $results) {
    try {
        Set-Annotation -Entity $result.VMHost -CustomAttribute $attr_Status      -Value $result.Status             | Out-Null
        Set-Annotation -Entity $result.VMHost -CustomAttribute $attr_Code        -Value ([string]$result.Code)     | Out-Null
        Set-Annotation -Entity $result.VMHost -CustomAttribute $attr_Codename    -Value $result.MatchedCodename    | Out-Null
        Set-Annotation -Entity $result.VMHost -CustomAttribute $attr_Series      -Value $result.MatchedSeries      | Out-Null
        Set-Annotation -Entity $result.VMHost -CustomAttribute $attr_VCFVersion  -Value $VCFVersion                | Out-Null
        Set-Annotation -Entity $result.VMHost -CustomAttribute $attr_KBReference -Value $KB_URL                   | Out-Null

        $statusIcon = switch ($result.Code) { 2 { $icon_red } 1 { $icon_yellow } default { $icon_green } }
        Write-Host "  $icon_ok $statusIcon  $($result.HostName.PadRight(30)) -> [$($result.Status)]" -ForegroundColor Green
        $successCount++
    } catch {
        Write-Host "  $icon_fail  $($result.HostName) -- $_" -ForegroundColor Red
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
Write-SectionHeader -Title "ENVIRONMENT SUMMARY   (VCF $VCFVersion)" -Icon $icon_summary
Write-Host ""

$results | Group-Object Status |
    Sort-Object { @{"Discontinued"=2;"Deprecated"=1;"Supported"=0}[$_.Name] } -Descending |
    ForEach-Object {
        $statusIcon = switch ($_.Name) { "Discontinued" { $icon_red } "Deprecated" { $icon_yellow } default { $icon_green } }
        $color      = switch ($_.Name) { "Discontinued" { "Red" }     "Deprecated" { "Yellow" }     default { "Green" } }
        Write-Host "  $statusIcon  $($_.Name.PadRight(15)) : $($_.Count) Host(s)" -ForegroundColor $color
        $_.Group | Where-Object { $_.Code -gt 0 } | ForEach-Object {
            Write-Host "       $icon_info  $($_.HostName)  |  $($_.CpuModel)  |  $($_.MatchedCodename)" -ForegroundColor DarkGray
        }
    }

Write-Host ""
Write-Host "  $icon_ok  Total Attributes Written : $successCount host(s)" -ForegroundColor Green
Write-Host "  $icon_info  KB Reference             : $KB_URL" -ForegroundColor DarkGray
Write-Host ""

# Disconnect
try {
    Disconnect-VIServer -Server $vCenterHost -Confirm:$false
} catch { }

Write-Host ("═" * 80) -ForegroundColor Cyan
Write-Host "  $icon_done  Script completed successfully." -ForegroundColor Cyan
Write-Host ("═" * 80) -ForegroundColor Cyan
Write-Host ""
