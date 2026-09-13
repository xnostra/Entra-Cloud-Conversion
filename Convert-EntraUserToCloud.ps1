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
    [switch]$PassThru,
    [switch]$NoGui,
    [ValidateSet('Convert', 'Restore')][string]$Action = 'Convert',
    [switch]$RestorePrerequisitesConfirmed
)

$ErrorActionPreference = 'Stop'
$showDialogs = -not $NoGui

function New-CloudDialog {
    param([string]$Title, [string]$Heading, [string]$Description, [string]$ButtonText, [switch]$ReadOnly)
    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Title
    $form.ClientSize = New-Object System.Drawing.Size(720, 500)
    $form.MinimumSize = New-Object System.Drawing.Size(600, 440)
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $form.BackColor = [System.Drawing.Color]::White
    $form.TopMost = $true
    $headingLabel = New-Object System.Windows.Forms.Label
    $headingLabel.SetBounds(24, 20, 672, 32)
    $headingLabel.Anchor = 'Top, Left, Right'
    $headingLabel.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
    $headingLabel.Text = $Heading
    $descriptionLabel = New-Object System.Windows.Forms.Label
    $descriptionLabel.SetBounds(24, 62, 672, 62)
    $descriptionLabel.Anchor = 'Top, Left, Right'
    $descriptionLabel.Text = $Description
    $box = New-Object System.Windows.Forms.TextBox
    $box.SetBounds(24, 132, 672, 292)
    $box.Anchor = 'Top, Bottom, Left, Right'
    $box.Multiline = $true
    $box.AcceptsReturn = $true
    $box.ScrollBars = 'Vertical'
    $box.ReadOnly = [bool]$ReadOnly
    $box.MaxLength = 0
    $box.Font = New-Object System.Drawing.Font('Consolas', 10)
    $box.BackColor = [System.Drawing.Color]::FromArgb(247, 249, 252)
    $button = New-Object System.Windows.Forms.Button
    $button.SetBounds(576, 446, 120, 34)
    $button.Anchor = 'Bottom, Right'
    $button.Text = $ButtonText
    $button.DialogResult = 'OK'
    $form.Controls.AddRange(@($headingLabel, $descriptionLabel, $box, $button))
    # Enter stays a newline in the email box; only clicking Start starts the run.
    [pscustomobject]@{ Form = $form; Box = $box; Button = $button; Heading = $headingLabel }
}

function Show-CloudInput {
    $dialog = New-CloudDialog -Title 'Entra Cloud Conversion' -Heading 'Convert or restore users' -Description "Choose an action, then paste one email or a list (one per line).`r`nRestore returns management to local AD; it does not recover deleted accounts." -ButtonText 'Start'
    $convert = New-Object System.Windows.Forms.RadioButton
    $convert.Text = 'Convert - manage in cloud'
    $convert.SetBounds(24, 124, 320, 30)
    $convert.Checked = $Action -eq 'Convert'
    $restore = New-Object System.Windows.Forms.RadioButton
    $restore.Text = 'Restore - manage in local AD'
    $restore.SetBounds(352, 124, 340, 30)
    $restore.Checked = $Action -eq 'Restore'
    $dialog.Form.Controls.AddRange(@($convert, $restore))
    $dialog.Box.SetBounds(24, 168, 672, 256)
    $dialog.Button.Enabled = $false
    $inputBox = $dialog.Box
    $startButton = $dialog.Button
    $inputBox.Add_TextChanged({ $startButton.Enabled = -not [string]::IsNullOrWhiteSpace($inputBox.Text) }.GetNewClosure())
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'
    $cancel.SetBounds(444, 446, 120, 34)
    $cancel.Anchor = 'Bottom, Right'
    $cancel.DialogResult = 'Cancel'
    $dialog.Form.CancelButton = $cancel
    $dialog.Form.Controls.Add($cancel)
    try {
        if ($dialog.Form.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $selected = 'Convert'
            if ($restore.Checked) { $selected = 'Restore' }
            return [pscustomobject]@{ Users = $dialog.Box.Text; Action = $selected }
        }
        return $null
    } finally { $dialog.Form.Dispose() }
}

function Show-CloudSummary {
    param([object[]]$Rows, [string]$FatalError)
    if ($FatalError) {
        $heading = 'Unable to complete the run'
        $description = 'The run stopped. Review the error below and try again.'
        $detail = $FatalError
        $color = [System.Drawing.Color]::Firebrick
    } else {
        $success = @($Rows | Where-Object Status -eq 'Success').Count
        $failed = @($Rows | Where-Object Status -eq 'Failed').Count
        $unverified = @($Rows | Where-Object Status -eq 'Unverified').Count
        $skipped = @($Rows | Where-Object Status -eq 'Skipped').Count
        $preview = @($Rows | Where-Object Status -eq 'Preview').Count
        $pending = @($Rows | Where-Object Status -eq 'PendingSync').Count
        $heading = 'Conversion completed successfully'
        $color = [System.Drawing.Color]::DarkGreen
        if ($failed + $unverified -gt 0) { $heading = 'Completed - some accounts need attention'; $color = [System.Drawing.Color]::Firebrick }
        elseif ($preview -gt 0) { $heading = 'Preview complete - no accounts changed'; $color = [System.Drawing.Color]::SteelBlue }
        elseif ($success -eq 0) { $heading = 'Complete - no accounts changed'; $color = [System.Drawing.Color]::SteelBlue }
        if ($Action -eq 'Restore' -and $success -gt 0 -and $failed + $unverified -eq 0) { $heading = 'Restore verified - review final steps' }
        if ($pending -gt 0) { $heading = 'Restore pending - sync required'; $color = [System.Drawing.Color]::DarkOrange }
        if ($pending -gt 0 -and $failed + $unverified -gt 0) { $heading = 'Restore pending - some accounts need attention' }
        $description = "Action: $Action | Success: $success | Skipped: $skipped | Preview: $preview`r`nFailed: $failed | Unverified: $unverified | Pending sync: $pending | Total: $($Rows.Count)"
        $detail = (@($Rows | ForEach-Object {
            "[$($_.Status)] $($_.Input)`r`nResolved UPN: $($_.UPN)`r`n$($_.Detail)"
        }) -join "`r`n`r`n")
        if ($Action -eq 'Restore') {
            $detail += "`r`n`r`nFINAL STEPS: Run a sync cycle on the working sync server. Rerun Restore to check progress. Once takeover is verified for all intended users, your administrator must re-enable blockCloudObjectTakeoverThroughHardMatchEnabled. This tool does not change that tenant-wide protection."
        }
    }
    $dialog = New-CloudDialog -Title 'Entra Cloud Conversion - Results' -Heading $heading -Description $description -ButtonText 'Close' -ReadOnly
    $dialog.Heading.ForeColor = $color
    $dialog.Box.Text = $detail
    $dialog.Form.AcceptButton = $dialog.Button
    $dialog.Form.CancelButton = $dialog.Button
    try { $null = $dialog.Form.ShowDialog() } finally { $dialog.Form.Dispose() }
}

try {
if ($showDialogs) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
}
if (-not $Users -and $showDialogs) {
    $selection = Show-CloudInput
    if (-not $selection) { Write-Host 'Cancelled. No accounts changed.'; return }
    $Users = $selection.Users
    $Action = $selection.Action
} elseif (-not $Users) {
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
if ($Action -eq 'Restore' -and -not $RestorePrerequisitesConfirmed -and -not $WhatIfPreference) {
    $prerequisiteMessage = "Restore requires the original matching AD accounts to exist, a working sync server, and the users to be in sync scope. Cloud-group and access-package dependencies must be reviewed and resolved first.`r`n`r`nThis does not restore deleted users or undo cloud password/profile changes. Local AD can overwrite cloud values when syncing resumes.`r`n`r`nHave you checked these prerequisites for every address in this run?"
    if ($showDialogs) {
        $answer = [System.Windows.Forms.MessageBox]::Show($prerequisiteMessage, 'Restore - prerequisite check', 'YesNo', 'Warning', 'Button2')
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { Write-Host 'Cancelled. No accounts changed.'; return }
    } else { throw ($prerequisiteMessage + ' Rerun with -RestorePrerequisitesConfirmed after checking.') }
}

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
if ($Action -eq 'Restore') { $connection.Scopes += 'OnPremDirectorySynchronization.Read.All' }
Connect-MgGraph @connection
$context = Get-MgContext
if (-not $context -or $context.AuthType -ne 'Delegated') { throw 'A delegated Graph sign-in is required.' }
if ($TenantId -and $TenantId -match '^[0-9a-fA-F-]{36}$' -and $context.TenantId -ne $TenantId) {
    throw 'Connected tenant does not match the requested tenant.'
}
Write-Host ("Connected: {0} | Tenant: {1}" -f $context.Account, $context.TenantId)

$base = 'https://graph.microsoft.com/v1.0'
$restoreBlocked = $null
if ($Action -eq 'Restore') {
    $configs = Invoke-MgGraphRequest -Method GET -Uri "$base/directory/onPremisesSynchronization" -OutputType PSObject -ErrorAction Stop
    $configList = @($configs.value)
    if ($configList.Count -ne 1 -or $configs.'@odata.nextLink') { throw 'Cannot uniquely resolve the tenant sync configuration. Restore stopped without changes.' }
    $protection = $configList[0].features.blockCloudObjectTakeoverThroughHardMatchEnabled
    if ($protection -isnot [bool]) { throw 'Cannot verify cloud-object takeover protection. Restore stopped without changes.' }
    if ($protection) {
        $restoreBlocked = 'Restore blocked: your Global Administrator must temporarily disable blockCloudObjectTakeoverThroughHardMatchEnabled for a planned rollback window, then re-enable it after sync takeover completes. See the README Restore section. No tenant settings were changed.'
    }
}
$seenIds = @{}
$processed = 0
$results = foreach ($inputAddress in $inputs) {
    $processed++
    Write-Progress -Activity 'Processing user management changes' -Status "$Action - $processed of $($inputs.Count): $inputAddress" -PercentComplete (($processed / $inputs.Count) * 100)
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
            if ($Action -eq 'Restore') {
                if ($state.isCloudManaged -eq $false) {
                    if ($user.onPremisesSyncEnabled -eq $true) {
                        $row.Status = 'Success'
                        $row.Detail = 'Verified: isCloudManaged=false and onPremisesSyncEnabled=true. Already managed by AD; no change made.'
                    } else {
                        $row.Status = 'Skipped'
                        $row.Detail = 'isCloudManaged=false but sync takeover is not verified. May be cloud-native or awaiting sync. No change made; check the original AD account and sync server.'
                    }
                } elseif ($restoreBlocked) { throw $restoreBlocked }
                elseif ($PSCmdlet.ShouldProcess("$($user.userPrincipalName) [$($user.id)]", 'Restore Source of Authority to local AD')) {
                    $patchAttempted = $true
                    $null = Invoke-MgGraphRequest -Method PATCH -Uri $behaviorUri -Body '{"isCloudManaged":false}' -ContentType 'application/json' -ErrorAction Stop
                    $verified = $false
                    for ($attempt = 1; $attempt -le $VerificationAttempts; $attempt++) {
                        $check = Invoke-MgGraphRequest -Method GET -Uri $behaviorUri -OutputType PSObject -ErrorAction Stop
                        if ($check.isCloudManaged -is [bool] -and $check.isCloudManaged -eq $false) { $verified = $true; break }
                        if ($attempt -lt $VerificationAttempts) { Start-Sleep -Seconds $VerificationDelaySeconds }
                    }
                    if (-not $verified) { throw 'Restore request could not be verified. Recheck isCloudManaged before retrying.' }
                    $syncCheck = Invoke-MgGraphRequest -Method GET -Uri "$base/users/$($user.id)?`$select=id,onPremisesSyncEnabled" -OutputType PSObject -ErrorAction Stop
                    $row.Status = 'PendingSync'
                    $row.Detail = 'Verified isCloudManaged=false. Restore is NOT complete: run a sync cycle on the working sync server, then recheck. Re-enable takeover protection after completion.'
                    if ($syncCheck.onPremisesSyncEnabled -eq $true) {
                        $row.Status = 'Success'
                        $row.Detail = 'Verified isCloudManaged=false and onPremisesSyncEnabled=true. AD management restored. Re-enable takeover protection once all intended users have completed.'
                    }
                } else {
                    $row.Status = 'Skipped'; $row.Detail = 'Restore declined.'
                    if ($WhatIfPreference) { $row.Status = 'Preview'; $row.Detail = 'Would set isCloudManaged=false; a sync cycle must finish the restore.' }
                }
            } elseif ($state.isCloudManaged -eq $true) {
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
$counts = foreach ($status in @('Success', 'Skipped', 'Preview', 'Failed', 'Unverified', 'PendingSync')) {
    '{0}: {1}' -f $status, @($results | Where-Object Status -eq $status).Count
}
Write-Host ($counts -join ' | ')
Write-Progress -Activity 'Processing user management changes' -Completed
if ($Action -eq 'Restore') { Write-Host 'After verified sync takeover, your administrator must re-enable blockCloudObjectTakeoverThroughHardMatchEnabled. See the README Restore section.' }
if ($showDialogs) { Show-CloudSummary -Rows @($results) }
if ($PassThru) { $results }
} catch {
    if ($showDialogs -and ('System.Windows.Forms.Form' -as [type])) {
        Show-CloudSummary -FatalError $_.Exception.Message
    }
    throw
} finally {
    Write-Progress -Activity 'Processing user management changes' -Completed
}
