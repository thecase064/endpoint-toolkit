# Intune primary user

After a build, Intune usually lists whoever set the PC up as its **primary user**. This changes it to the real user, or removes it for a shared device. Run it on the PC itself.

```powershell
Set-IntunePrimaryUser                                        # show the current primary user, change nothing
Set-IntunePrimaryUser -UserPrincipalName jane.doe@contoso.com
Set-IntunePrimaryUser -Remove                                # shared device
```

New device setup can run it as its first step: give it a user (or tick remove) when you start the build.

## What it does

1. Reads from the PC itself: that it's Entra joined, which tenant, and its Intune device ID. No typing tenant names, and no chance of changing the wrong device.
2. Signs in to that tenant with Microsoft's sign-in window, so MFA and Windows Hello work as normal.
   - It asks for `DeviceManagementManagedDevices.ReadWrite.All` and `User.Read.All`. Just looking only needs the read-only versions.
   - Over a remote session there's no desktop for a sign-in window, so it uses a device code instead (microsoft.com/devicelogin on your own machine). Some tenants block device code sign-in.
3. Shows the device, its serial, who enrolled it and the current primary user.
4. Sets the new primary user, or removes it, through Microsoft Graph. Then it checks Intune has taken the change: up to four checks, five seconds apart.
5. Signs out.

| Changes | Doesn't change |
|---|---|
| Intune primary user | The "Enrolled by" user |
| Entra device owner and registered user (Intune updates these to match) | The Autopilot assigned user |
| | Who is a local administrator on the PC |

## Needs

- The PC Entra joined and enrolled in Intune. A freshly enrolled PC can take a few minutes to appear in Intune; it says so and you can run it again.
- An admin with **Intune Administrator** or **Help Desk Operator** in that tenant.
- Consent for **Microsoft Graph Command Line Tools** in that tenant. If nobody has used it there before, the first sign-in asks a Global Admin to consent.

## The sign-in module

It uses Microsoft's `Microsoft.Graph.Authentication` module. If that's already installed, it's used as is. If not, it's downloaded from the PowerShell Gallery into a cache:

- `C:\ProgramData\EndpointToolkit\_modules` when run as admin
- `%LOCALAPPDATA%\EndpointToolkit\_modules` otherwise

Nothing is loaded unless:

- every DLL in it is validly signed;
- no file has a broken signature;
- the module's own DLL is signed by Microsoft.

Otherwise the download is deleted and it stops. The cache is reused next time. New device setup deletes it at the end of a build.

## Exit codes

`0` done, or nothing needed changing (already the primary user, or nothing to remove). `1` couldn't do it, with the reason shown: not joined, not enrolled, not in Intune yet, user not found, no permission, or sign-in cancelled.

`-ResultFile <path>` writes the outcome as JSON: before, after, who signed in, tenant, message. New device setup uses it for the build report.
