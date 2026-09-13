# Entra Cloud Conversion

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

Single user (applies the transfer):

```powershell
.\Convert-EntraUserToCloud.ps1 -Users 'user@contoso.com'
```

Paste any number of addresses when prompted; finish with an empty line:

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

## GitHub one-liner

Run directly from this repository. The one-liners use the latest version on `main`.
For a fixed version, replace `main` in the URL with a reviewed commit SHA.

Download and run, then paste one or several addresses at the prompt:

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

The same user object is retained. The script makes no password changes; verify
sign-in separately, especially if authentication still depends on federation or
on-premises infrastructure. `isCloudManaged` is the transfer verification flag;
do not rely solely on the portal's sync label.

## Microsoft references

- [Configure user SOA, prerequisites and v1.0 transfer API](https://learn.microsoft.com/en-us/entra/identity/hybrid/how-to-user-source-of-authority-configure)
- [Graph user list and permissions](https://learn.microsoft.com/en-us/graph/api/user-list?view=graph-rest-1.0)

Validated locally with simulated Graph responses; no live tenant transfer was
performed while preparing this script.
