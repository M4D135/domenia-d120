# D004 test fixtures only: Active Directory value shapes, never loaded by the application.
# Binary GUID and SID, FILETIME integers and IADsLargeInteger-like values, attribute collections with
# zero, one or several values, absent attributes. Synthetic data only (example.invalid, documentation SIDs).
# Rule kept by every helper: a single value (one byte array, one string, one object) stays ONE element.

function New-DomeniaFixtureGuidBytes {
    param([Parameter(Mandatory=$true)][guid]$Guid)
    $bytes=$Guid.ToByteArray()
    return ,$bytes
}

function New-DomeniaFixtureSidBytes {
    param([Parameter(Mandatory=$true)][string]$Sid)
    $identifier=New-Object Security.Principal.SecurityIdentifier -ArgumentList $Sid
    $bytes=New-Object byte[] $identifier.BinaryLength
    $identifier.GetBinaryForm($bytes,0)
    return ,$bytes
}

function ConvertTo-DomeniaFixtureFileTime {
    # AD time attributes (lastLogonTimestamp, pwdLastSet, accountExpires) are 100 ns ticks since 1601 UTC.
    param([Parameter(Mandatory=$true)][datetime]$Utc)
    return [long]$Utc.ToUniversalTime().ToFileTimeUtc()
}

function New-DomeniaFixtureLargeInteger {
    # Shape of the COM IADsLargeInteger returned through DirectoryEntry: signed 32-bit HighPart and LowPart.
    param([long]$Value)
    $high=[int]($Value -shr 32)
    $lowBits=($Value -band 0xFFFFFFFFL)
    $low=if($lowBits -gt [long][int]::MaxValue){[int]($lowBits-4294967296L)}else{[int]$lowBits}
    return [pscustomobject]@{HighPart=$high;LowPart=$low}
}

function New-DomeniaFixtureSingleValue {
    # One attribute holding exactly one value, whatever its type (a byte[] is kept whole).
    param($Value)
    $list=New-Object Collections.ArrayList
    [void]$list.Add($Value)
    return ,$list
}

function New-DomeniaFixtureValues {
    # One attribute holding zero or several values. Pass @() for an empty attribute.
    param([object[]]$Values=@())
    $list=New-Object Collections.ArrayList
    foreach($value in @($Values)){[void]$list.Add($value)}
    return ,$list
}

function New-DomeniaFixtureProperties {
    # DirectorySearcher-like property bag: case-insensitive attribute names, every value is a collection.
    param([hashtable]$Attributes=@{})
    $bag=New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
    foreach($name in @($Attributes.Keys)){$bag[[string]$name]=$Attributes[$name]}
    return $bag
}

function New-DomeniaFixtureDirectoryEntry {
    # DirectoryEntry stand-in for Get-WAllProperties: RefreshCache(string[]) and a Properties bag.
    param([hashtable]$Attributes=@{})
    if($null -eq ('DomeniaFixture.DirectoryEntryDouble' -as [type])){
        Add-Type -Language CSharp -TypeDefinition @'
namespace DomeniaFixture
{
    public sealed class DirectoryEntryDouble
    {
        private readonly System.Collections.Hashtable properties;
        private readonly System.Collections.Generic.List<string> refreshed = new System.Collections.Generic.List<string>();
        public DirectoryEntryDouble(System.Collections.Hashtable properties) { this.properties = properties; }
        public System.Collections.Hashtable Properties { get { return properties; } }
        public void RefreshCache(string[] names) { if (names != null) { refreshed.AddRange(names); } }
        public string[] Refreshed { get { return refreshed.ToArray(); } }
    }
}
'@
    }
    return New-Object DomeniaFixture.DirectoryEntryDouble -ArgumentList @(,(New-DomeniaFixtureProperties $Attributes))
}

function Get-DomeniaFixtureCatalog {
    # Reference objects shared by the suites. GUIDs and SIDs are synthetic.
    $userGuid=[guid]'5f0c8a3e-1d2b-4c6a-9e7f-102030405060'
    $computerGuid=[guid]'0a1b2c3d-4e5f-4a6b-8c7d-8e9fa0b1c2d3'
    return [pscustomobject]@{
        UserGuid=$userGuid;ComputerGuid=$computerGuid
        UserSid='S-1-5-21-1004336348-1177238915-682003330-1104'
        GroupSid='S-1-5-21-1004336348-1177238915-682003330-513'
        UserDn='CN=Alex Demo,OU=Utilisateurs,DC=example,DC=invalid'
        ComputerDn='CN=PC-DEMO-01,OU=Postes,DC=example,DC=invalid'
        GroupDns=@('CN=Support N1,OU=Groupes,DC=example,DC=invalid','CN=Imprimantes,OU=Groupes,DC=example,DC=invalid','CN=VPN,OU=Groupes,DC=example,DC=invalid')
        LogonUtc=[datetime]::new(2026,9,30,7,45,12,[DateTimeKind]::Utc)
    }
}
