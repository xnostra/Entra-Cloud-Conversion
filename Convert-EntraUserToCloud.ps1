#requires -Version 5.1
<#
.SYNOPSIS
Transfers synced users to cloud Source of Authority using Microsoft Graph v1.0.
.DESCRIPTION
Requires Microsoft.Graph.Authentication, delegated User.Read.All and
User-OnPremisesSyncBehavior.ReadWrite.All, and the Hybrid Identity Administrator
role (or another supported role). No password or immutable ID changes are made.
Matches exact UPN or primary mail; ambiguous matches fail without a write.
.EXAMPLE
.\Convert-EntraUserToCloud.ps1 -Users 'user@contoso.com'
.EXAMPLE
.\Convert-EntraUserToCloud.ps1 -Users (Get-Clipboard -Raw) -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Alias('Emails', 'UPNs')]
    [string[]]$Users,
    [string]$TenantId,
    [switch]$UseDeviceCode,
    [ValidateRange(1, 20)][int]$VerificationAttempts = 6,
    [ValidateRange(1, 30)][int]$VerificationDelaySeconds = 2,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
if (-not $Users) {
    Write-Host 'Paste emails/UPNs (one per line, or separated by spaces, commas or semicolons).'
    Write-Host 'Press Enter on an empty line to start.'
    $lines = @()
    do {
        $line = Read-Host
        if (-not [string]::IsNullOrWhiteSpace($line)) { $lines += $line }
    } while (-not [string]::IsNullOrWhiteSpace($line))
    $Users = $lines
}
$inputs = @($Users -split '[\s,;]+' | Where-Object { $_ } | Sort-Object -Unique)
if ($inputs.Count -eq 0) { throw 'No emails/UPNs supplied.' }

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    throw 'Install the required module once, then retry: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Repository PSGallery'
}
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
$connection = @{
    Scopes = @('User.Read.All', 'User-OnPremisesSyncBehavior.ReadWrite.All')
    ContextScope = 'Process'
    Environment = 'Global'
    NoWelcome = $true
    ErrorAction = 'Stop'
}
if ($TenantId) { $connection.TenantId = $TenantId }
if ($UseDeviceCode) { $connection.UseDeviceCode = $true }
Connect-MgGraph @connection
$context = Get-MgContext
if (-not $context -or $context.AuthType -ne 'Delegated') { throw 'A delegated Graph sign-in is required.' }
if ($TenantId -and $TenantId -match '^[0-9a-fA-F-]{36}$' -and $context.TenantId -ne $TenantId) {
    throw 'Connected tenant does not match the requested tenant.'
}
Write-Host ("Connected: {0} | Tenant: {1}" -f $context.Account, $context.TenantId)

$base = 'https://graph.microsoft.com/v1.0'
$seenIds = @{}
$results = foreach ($inputAddress in $inputs) {
    $row = [ordered]@{ Input = $inputAddress; UPN = ''; UserId = ''; Status = 'Failed'; Detail = '' }
    $patchAttempted = $false
    try {
        if ($inputAddress -notmatch '^[^\s@]+@[^\s@]+$') { throw 'Invalid email/UPN format.' }
        # Resolve both identities together so a UPN/mail collision is never guessed.
        $literal = $inputAddress.Replace("'", "''")
        $filter = [uri]::EscapeDataString("userPrincipalName eq '$literal' or mail eq '$literal'")
        $uri = "$base/users?`$filter=$filter&`$select=id,userPrincipalName,mail,onPremisesSyncEnabled"
        $matches = @()
        do {
            $page = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject -ErrorAction Stop
            $matches += @($page.value)
            $uri = $page.'@odata.nextLink'
        } while ($uri)
        $matches = @($matches | Where-Object { $_.id } | Sort-Object id -Unique)
        if ($matches.Count -eq 0) { throw 'No exact UPN or primary email match. Try the sign-in UPN.' }
        if ($matches.Count -gt 1) { throw 'Ambiguous UPN/email: multiple users matched; no change made.' }
        $user = $matches[0]
        $row.UPN = $user.userPrincipalName
        $row.UserId = $user.id
        if ($seenIds.ContainsKey($user.id)) {
            $row.Status = 'Skipped'
            $row.Detail = 'Same user already processed in this run.'
        } else {
            $seenIds[$user.id] = $true
            $behaviorUri = "$base/users/$($user.id)/onPremisesSyncBehavior"
            $state = Invoke-MgGraphRequest -Method GET -Uri $behaviorUri -OutputType PSObject -ErrorAction Stop
            if ($state.isCloudManaged -isnot [bool]) { throw 'Graph did not return a Boolean isCloudManaged; no change made.' }
            if ($state.isCloudManaged -eq $true) {
                $row.Status = 'Skipped'
                $row.Detail = 'Already cloud-managed (isCloudManaged=true).'
            } elseif ($user.onPremisesSyncEnabled -ne $true) {
                $row.Status = 'Skipped'
                $row.Detail = 'Not currently synced; no transfer needed or attempted.'
            } elseif ($PSCmdlet.ShouldProcess("$($user.userPrincipalName) [$($user.id)]", 'Transfer Source of Authority to cloud')) {
                $patchAttempted = $true
                $null = Invoke-MgGraphRequest -Method PATCH -Uri $behaviorUri -Body '{"isCloudManaged":true}' -ContentType 'application/json' -ErrorAction Stop
                $verified = $false
                $lastCheck = 'isCloudManaged was not true.'
                for ($attempt = 1; $attempt -le $VerificationAttempts; $attempt++) {
                    try {
                        $check = Invoke-MgGraphRequest -Method GET -Uri $behaviorUri -OutputType PSObject -ErrorAction Stop
                        if ($check.isCloudManaged -is [bool] -and $check.isCloudManaged -eq $true) {
                            $verified = $true
                            break
                        }
                        $lastCheck = 'isCloudManaged was not true.'
                    } catch { $lastCheck = $_.Exception.Message }
                    if ($attempt -lt $VerificationAttempts) { Start-Sleep -Seconds $VerificationDelaySeconds }
                }
                if (-not $verified) { throw "Verification not confirmed after $VerificationAttempts checks: $lastCheck" }
                $row.Status = 'Success'
                $row.Detail = 'Verified isCloudManaged=true.'
            } else {
                $row.Status = 'Skipped'
                if ($WhatIfPreference) { $row.Status = 'Preview'; $row.Detail = 'Would transfer synced user to cloud.' }
                else { $row.Detail = 'Transfer declined.' }
            }
        }
    } catch {
        $row.Detail = ($_.Exception.Message -replace '\s+', ' ').Trim()
        if ($patchAttempted) {
            $row.Status = 'Unverified'
            $row.Detail = 'PATCH attempted; outcome not confirmed. Recheck before retrying. ' + $row.Detail
        }
    }
    [pscustomobject]$row
}
$results | Format-Table Input, UPN, Status, Detail -AutoSize -Wrap | Out-Host
$counts = foreach ($status in @('Success', 'Skipped', 'Preview', 'Failed', 'Unverified')) {
    '{0}: {1}' -f $status, @($results | Where-Object Status -eq $status).Count
}
Write-Host ($counts -join ' | ')
if ($PassThru) { $results }
