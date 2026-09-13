# Entra Cloud Conversion

Choose **Convert** or **Restore**, paste one email or a list into the popup, click **Start**, and sign in to Microsoft
Graph. A result window shows what happened to each account, with totals for
successful conversions, skipped accounts, failures and unverified outcomes.

`Convert-EntraUserToCloud.ps1` transfers single or multiple synced users using
`PATCH https://graph.microsoft.com/v1.0/users/{id}/onPremisesSyncBehavior`
with only `{"isCloudManaged":true}`. It does not reset passwords, clear immutable
IDs, delete/recreate accounts, or change tenant-wide sync settings.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7; Microsoft public/global cloud.
- Hybrid Identity Administrator (Microsoft's SOA guide calls this Hybrid Administrator), or a supported higher role.
- Admin consent for delegated `User-OnPremisesSyncBehavior.ReadWrite.All` and
  `User.Read.All` (user lookup and sync status).
- For your sync engine: Entra Connect Sync 2.5.76.0 or later, or Cloud Sync agent
  1.1.1370.0 or later. The script does not inspect the sync server version.

Install the small authentication module once:

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Repository PSGallery
```

## Run

**Open the popup directly from GitHub:**

```powershell
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/xnostra/Entra-Cloud-Conversion/main/Convert-EntraUserToCloud.ps1')))
```

1. Choose **Convert - manage in cloud** or **Restore - manage in local AD**.
   Paste one email or multiple emails into the large box. Use one per line,
   spaces, commas or semicolons.
2. Click **Start**. **Cancel**, Escape, or closing the input window exits without changes.
3. Sign in when prompted. Progress appears in PowerShell while accounts are processed.
4. Read the results popup. It lists every account and its outcome. Text can be
   selected and copied for your records; click **Close** when finished.

The Start button remains disabled for empty input. A failed connection or missing
module also opens an error popup. Install the module above before the first run.

Single user (applies the transfer):

```powershell
.\Convert-EntraUserToCloud.ps1 -Users 'user@contoso.com'
```

Open the same popup from a downloaded copy:

```powershell
.\Convert-EntraUserToCloud.ps1
```

Copy a list of addresses, then preview it:

```powershell
.\Convert-EntraUserToCloud.ps1 -Users (Get-Clipboard -Raw) -WhatIf
```

Remove `-WhatIf` to apply. Or use a multiline string:

```powershell
.\Convert-EntraUserToCloud.ps1 -Users @'
first@contoso.com
second@contoso.com
'@
```

Arrays, comma-separated, semicolon-separated and whitespace-separated addresses
also work. Supply addresses only, without a header or display names. Matches use
exact UPN or primary `mail`; secondary SMTP aliases are not searched. Any ambiguous
match fails without modifying that user. Duplicate inputs and duplicate resolved
object IDs are processed once. One user's error does not stop other users.

Optional: `-TenantId 'your-tenant-guid'` targets a tenant; `-UseDeviceCode` uses
device login; `-PassThru` returns result objects for export or automation.
`-NoGui` disables popups for console use; when no `-Users` is supplied in that mode,
paste addresses into the console and finish with an empty line.

The popup requires a Windows desktop session. Use Windows PowerShell or PowerShell
7 on Windows in STA mode (their normal Windows console default). If your host uses
MTA, start `powershell.exe -STA` or `pwsh.exe -STA`, then paste the command there.

## GitHub one-liner

Run directly from this repository. The one-liners use the latest version on `main`.
For a fixed version, replace `main` in the URL with a reviewed commit SHA.

Download and run, then paste one or several addresses into the popup and click **Start**:

```powershell
& ([scriptblock]::Create((Invoke-RestMethod 'https://raw.githubusercontent.com/xnostra/Entra-Cloud-Conversion/main/Convert-EntraUserToCloud.ps1')))
```

Single-user invocation:

```powershell
& ([scriptblock]::Create((Invoke-RestMethod 'https://raw.githubusercontent.com/xnostra/Entra-Cloud-Conversion/main/Convert-EntraUserToCloud.ps1'))) -Users 'user@contoso.com'
```

Clipboard list preview (remove `-WhatIf` to apply):

```powershell
& ([scriptblock]::Create((Invoke-RestMethod 'https://raw.githubusercontent.com/xnostra/Entra-Cloud-Conversion/main/Convert-EntraUserToCloud.ps1'))) -Users (Get-Clipboard -Raw) -WhatIf
```

These download and execute the chosen script; use your trusted repository. The
module must already be installed. Private repositories need an authenticated
download instead of this public raw URL.

## Results

- Success: a subsequent GET confirmed Boolean `isCloudManaged=true`.
- Skipped: already cloud-managed, not currently synced, duplicate, or declined.
- Preview: eligible synced user; no PATCH sent (`-WhatIf`).
- Failed: lookup or preflight error; no PATCH attempted.
- Unverified: PATCH attempted but its outcome could not be confirmed. This can
  include server rejection, network failure or delayed readback. Read the detail;
  recheck the account before retrying. No rollback is attempted.
- PendingSync: Restore set and verified `isCloudManaged=false`, but AD takeover
  has not completed. Run a sync cycle on the working sync server and rerun Restore
  to verify. An account already at false without active sync is skipped with an
  explanation, because it may also be a cloud-native user.

## Restore to local AD

Restore reverses the per-user SOA transfer. It does not recover deleted accounts,
recreate local AD accounts, or undo changes made to passwords/profile values while
cloud-managed. It never clears immutable IDs or resets passwords.

Before clicking Start for Restore, check that the original matching AD accounts
exist, are in sync scope, and the sync server is working. Review and resolve cloud
references first, including SOA-transferred groups and their access-package
dependencies as required by Microsoft's rollback guide. The tool asks you to
confirm these external prerequisites; it cannot inspect your local AD or prove
that all cloud dependencies have been resolved.

Restore additionally requests `OnPremDirectorySynchronization.Read.All` to read
the sync protection configuration. Microsoft requires **Global Administrator**
for this read. Convert retains its original permissions and supported role.

An administrator must prepare a planned rollback window:

1. Review [Microsoft's rollback instructions](https://learn.microsoft.com/en-us/entra/identity/hybrid/how-to-user-source-of-authority-configure#roll-back-soa-update).
2. Temporarily set `features.blockCloudObjectTakeoverThroughHardMatchEnabled`
   to `false` on the correct `/directory/onPremisesSynchronization/{id}` object.
   This is a **tenant-wide** protection, so keep this window controlled and brief.
   Modifying it requires `OnPremDirectorySynchronization.ReadWrite.All` and
   Global Administrator. The tool intentionally requests read-only access to it
   and blocks Restore if it is still enabled or cannot be verified.
3. Use **Restore** for the intended users. The tool PATCHes only their
   `onPremisesSyncBehavior` with `{"isCloudManaged":false}` and reads it back.
4. Run the sync cycle on the working sync server. A dead server cannot complete
   Restore. Rerun Restore to check the users: success requires both
   `isCloudManaged=false` and `onPremisesSyncEnabled=true`.
5. Once all intended users have completed takeover, **re-enable**
   `blockCloudObjectTakeoverThroughHardMatchEnabled` and verify it is `true`.
   This remains the administrator's responsibility, even if a run fails or closes.

The tool does not weaken or change tenant-wide protection, delete group
memberships, or run commands on your sync server. Local AD values can overwrite
cloud changes once synchronization resumes.

Console example after checking prerequisites:

```powershell
.\Convert-EntraUserToCloud.ps1 -Action Restore -Users 'user@contoso.com' -NoGui -RestorePrerequisitesConfirmed
```

Use `-Action Restore -WhatIf` for a read-only eligibility check. Protection blocks
remain visible in preview. The existing GitHub one-liner opens both options.

The same user object is retained. The script makes no password changes; verify
sign-in separately, especially if authentication still depends on federation or
on-premises infrastructure. `isCloudManaged` is the transfer verification flag;
do not rely solely on the portal's sync label.

## Microsoft references

- [Configure user SOA, prerequisites and v1.0 transfer API](https://learn.microsoft.com/en-us/entra/identity/hybrid/how-to-user-source-of-authority-configure)
- [Graph user list and permissions](https://learn.microsoft.com/en-us/graph/api/user-list?view=graph-rest-1.0)
