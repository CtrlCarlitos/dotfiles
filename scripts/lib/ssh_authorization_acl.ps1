# Apply private ACLs to staged authorization files, or copy config security.
# Called only by scripts/lib/ssh_authorization.py; PowerShell 5.1/7 compatible.
param(
    [Parameter(Mandatory)][string]$Path,
    [string]$ReferencePath,
    [ValidateSet('Admin', 'User', 'Copy')][string]$Mode = 'User',
    [string]$UserSid
)
$ErrorActionPreference = 'Stop'
function Read-FileSecurity([string]$File) {
    $sections = [Security.AccessControl.AccessControlSections]'Access,Owner,Group'
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        return [IO.FileSystemAclExtensions]::GetAccessControl([IO.FileInfo]::new($File), $sections)
    }
    return [IO.File]::GetAccessControl($File, $sections)
}
$reference = if ($ReferencePath) { Read-FileSecurity $ReferencePath } else { Read-FileSecurity $Path }
if ($Mode -eq 'Copy') {
    $desired = $reference
} else {
    $desired = [Security.AccessControl.FileSecurity]::new()
    $desired.SetAccessRuleProtection($true, $false)
    $desired.SetOwner($reference.GetOwner([Security.Principal.SecurityIdentifier]))
    $desired.SetGroup($reference.GetGroup([Security.Principal.SecurityIdentifier]))
    if ($Mode -eq 'Admin') { $principal = 'S-1-5-32-544' }
    elseif ($UserSid) { $principal = $UserSid }
    else { $principal = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
    foreach ($sid in @($principal, 'S-1-5-18') | Select-Object -Unique) {
        $identity = [Security.Principal.SecurityIdentifier]::new($sid)
        $desired.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', 'Allow'))
    }
}
$sections = [Security.AccessControl.AccessControlSections]'Access,Owner,Group'
if ((Read-FileSecurity $Path).GetSecurityDescriptorSddlForm($sections) -eq $desired.GetSecurityDescriptorSddlForm($sections)) { exit 0 }
if ($PSVersionTable.PSVersion.Major -ge 6) {
    [IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($Path), $desired)
} else {
    [IO.File]::SetAccessControl($Path, $desired)
}
