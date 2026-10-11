# D004 : fixtures that reproduce the shapes Active Directory values take in Windows PowerShell 5.1.
# Test-only file: dot-sourced by wad/tests/rules/*.Tests.ps1, never loaded by the application.
# No directory, no network, no disk write, no user data: every value below is fictitious.
#
# Fidelity and limits (read before relying on a fixture):
# - objectGUID is a byte[16] in the order of [guid]::ToByteArray() (first three fields little-endian), as AD stores it.
# - objectSid is the binary SID (revision, sub-authority count, 48-bit big-endian authority, little-endian
#   sub-authorities). It is assembled by hand so that the converters under test are not checked against themselves.
# - Large-integer attributes (FILETIME: pwdLastSet, lastLogonTimestamp, accountExpires, lockoutTime; intervals:
#   maxPwdAge, lockoutDuration, lockOutObservationWindow) take TWO shapes, depending on the reader:
#     DirectorySearcher (SearchResult.Properties)  -> Int64, including 0 and 0x7FFFFFFFFFFFFFFF ("no date");
#     DirectoryEntry (Properties[name])            -> COM IADsLargeInteger, never an Int64.
#   In these fixtures an Int64 value is a large integer: every factory that builds a DirectoryEntry shape
#   (New-DomeniaFixturePropertyValues, New-DomeniaFixtureDirectoryProperties, bag 'DirectoryProperties') turns
#   each Int64 into an IADsLargeInteger. Int32 attributes (userAccountControl, primaryGroupID...) stay Int32.
# - System.DirectoryServices.ResultPropertyValueCollection, ResultPropertyCollection and SearchResult are the genuine
#   .NET Framework types, built through their internal constructors: nothing is bound and no request is sent.
#   When the assembly or those constructors are missing (another engine), C# 5 stand-ins deriving from the same base
#   classes are used and Initialize-DomeniaFixtureTypes reports Genuine = $false.
# - PropertyValueCollection and PropertyCollection (DirectoryEntry.Properties) cannot be built without binding a
#   DirectoryEntry: they are always emulated (CollectionBase / DictionaryBase) with the genuine Value semantics
#   (null when empty, the value itself when single, object[] otherwise). Names are stored lower-case.
# - SearchResultCollection needs a live ADSI search handle: it is always emulated (ICollection, IDisposable, indexer,
#   enumeration refused after Dispose).
# - IADsLargeInteger is GENUINE on Windows: the ADSI class "LargeInteger" (activeds.dll) is created in process with
#   New-Object -ComObject LargeInteger, no directory is bound. Like the object a DirectoryEntry returns, it is a
#   System.__ComObject on which PowerShell sees NO HighPart/LowPart member (observed under Windows PowerShell
#   5.1.26100.6584): only Type.InvokeMember('HighPart'/'LowPart', GetProperty) reads it. Elsewhere a C# stand-in
#   (LargeIntegerDouble) is used; it also answers InvokeMember but, unlike the genuine object, shows its members
#   to PowerShell: a converter validated only against the stand-in proves nothing. State: LargeIntegerGenuine.
# - ACE lists come from a genuine in-memory ActiveDirectorySecurity (GetAccessRules -> AuthorizationRuleCollection).
# - An attribute absent from an entry is simply missing from the property bag, as in a search result.
# - Observed in the test VM under Windows PowerShell 5.1.26100.6584: a collection that is ICollection but not IList
#   (SearchResultCollection, ResultPropertyValueCollection, AuthorizationRuleCollection) bound BY POSITION to an
#   [object[]] parameter arrives as ONE element (the collection itself); bound by name or wrapped in @() it is
#   enumerated. [string[]] parameters enumerate it in both cases. Fixtures.Tests.ps1 pins this down because every
#   rule with an [object[]] parameter is exposed.
# Every factory returning a collection uses "return ,$value" so that PowerShell does not unroll it on the way out.

$script:DomeniaFixtureSource = @'
using System;
using System.Collections;

namespace Domenia.Fixtures
{
    // Stand-in for System.DirectoryServices.ResultPropertyValueCollection when the genuine type cannot be built.
    public class ResultPropertyValueCollectionDouble : ReadOnlyCollectionBase
    {
        public ResultPropertyValueCollectionDouble(object[] values)
        {
            if (values != null) { InnerList.AddRange(values); }
        }
        public object this[int index] { get { return InnerList[index]; } }
        public bool Contains(object value) { return InnerList.Contains(value); }
        public int IndexOf(object value) { return InnerList.IndexOf(value); }
        public void CopyTo(object[] values, int index) { InnerList.CopyTo(values, index); }
    }

    // Stand-in for System.DirectoryServices.ResultPropertyCollection: lower-case names, empty collection for a missing name.
    public class ResultPropertyCollectionDouble : DictionaryBase
    {
        public ResultPropertyValueCollectionDouble this[string name]
        {
            get
            {
                string key = (name ?? string.Empty).ToLowerInvariant();
                if (Dictionary.Contains(key)) { return (ResultPropertyValueCollectionDouble)Dictionary[key]; }
                return new ResultPropertyValueCollectionDouble(new object[0]);
            }
        }
        public ICollection PropertyNames { get { return Dictionary.Keys; } }
        public ICollection Values { get { return Dictionary.Values; } }
        public bool Contains(string propertyName) { return Dictionary.Contains((propertyName ?? string.Empty).ToLowerInvariant()); }
        public void Add(string name, ResultPropertyValueCollectionDouble value) { Dictionary.Add(name.ToLowerInvariant(), value); }
    }

    // Stand-in for System.DirectoryServices.SearchResult when the genuine type cannot be built.
    public class SearchResultDouble
    {
        private readonly ResultPropertyCollectionDouble properties = new ResultPropertyCollectionDouble();
        public ResultPropertyCollectionDouble Properties { get { return properties; } }
        public string Path
        {
            get
            {
                ResultPropertyValueCollectionDouble values = properties["adspath"];
                if (values.Count == 0) { return string.Empty; }
                return (string)values[0];
            }
        }
    }

    // Stand-in for System.DirectoryServices.SearchResultCollection, which needs a live ADSI search handle.
    public class SearchResultCollectionDouble : MarshalByRefObject, ICollection, IEnumerable, IDisposable
    {
        private readonly ArrayList items = new ArrayList();
        private readonly string[] propertiesLoaded;
        private bool disposed;

        public SearchResultCollectionDouble(object[] results, string[] propertiesLoaded)
        {
            if (results != null) { items.AddRange(results); }
            this.propertiesLoaded = propertiesLoaded ?? new string[0];
        }
        public int Count { get { CheckAlive(); return items.Count; } }
        public object this[int index] { get { CheckAlive(); return items[index]; } }
        public string[] PropertiesLoaded { get { return (string[])propertiesLoaded.Clone(); } }
        public bool IsDisposed { get { return disposed; } }
        public bool Contains(object result) { CheckAlive(); return items.Contains(result); }
        public int IndexOf(object result) { CheckAlive(); return items.IndexOf(result); }
        public void CopyTo(object[] results, int index) { CheckAlive(); items.CopyTo(results, index); }
        public IEnumerator GetEnumerator() { CheckAlive(); return items.GetEnumerator(); }
        public void Dispose() { disposed = true; }
        bool ICollection.IsSynchronized { get { return false; } }
        object ICollection.SyncRoot { get { return this; } }
        void ICollection.CopyTo(Array array, int index) { CheckAlive(); items.CopyTo(array, index); }
        private void CheckAlive() { if (disposed) { throw new ObjectDisposedException("SearchResultCollection"); } }
    }

    // Stand-in for System.DirectoryServices.PropertyValueCollection (DirectoryEntry.Properties[name]).
    public class PropertyValueCollectionDouble : CollectionBase
    {
        private readonly string propertyName;
        public PropertyValueCollectionDouble(string propertyName, object[] values)
        {
            this.propertyName = propertyName ?? string.Empty;
            if (values != null) { foreach (object value in values) { InnerList.Add(value); } }
        }
        public string PropertyName { get { return propertyName; } }
        public object this[int index] { get { return InnerList[index]; } set { InnerList[index] = value; } }
        public object Value
        {
            get
            {
                if (InnerList.Count == 0) { return null; }
                if (InnerList.Count == 1) { return InnerList[0]; }
                object[] copy = new object[InnerList.Count];
                InnerList.CopyTo(copy, 0);
                return copy;
            }
        }
        public int Add(object value) { return InnerList.Add(value); }
        public bool Contains(object value) { return InnerList.Contains(value); }
        public int IndexOf(object value) { return InnerList.IndexOf(value); }
        public void CopyTo(object[] array, int index) { InnerList.CopyTo(array, index); }
    }

    // Stand-in for System.DirectoryServices.PropertyCollection (DirectoryEntry.Properties).
    public class PropertyCollectionDouble : DictionaryBase
    {
        public PropertyValueCollectionDouble this[string propertyName]
        {
            get
            {
                string key = (propertyName ?? string.Empty).ToLowerInvariant();
                if (Dictionary.Contains(key)) { return (PropertyValueCollectionDouble)Dictionary[key]; }
                return new PropertyValueCollectionDouble(propertyName, new object[0]);
            }
        }
        public ICollection PropertyNames { get { return Dictionary.Keys; } }
        public ICollection Values { get { return Dictionary.Values; } }
        public bool Contains(string propertyName) { return Dictionary.Contains((propertyName ?? string.Empty).ToLowerInvariant()); }
        public void Add(string name, PropertyValueCollectionDouble value) { Dictionary.Add(name.ToLowerInvariant(), value); }
    }

    // Stand-in for the COM IADsLargeInteger returned by DirectoryEntry for FILETIME attributes.
    public sealed class LargeIntegerDouble
    {
        private readonly int highPart;
        private readonly int lowPart;
        public LargeIntegerDouble(long value)
        {
            highPart = (int)(value >> 32);
            lowPart = unchecked((int)(value & 0xFFFFFFFFL));
        }
        public int HighPart { get { return highPart; } }
        public int LowPart { get { return lowPart; } }
        public override string ToString() { return "System.__ComObject"; }
    }
}
'@

if ($null -eq (Get-Variable -Name DomeniaFixtureState -Scope Script -ErrorAction SilentlyContinue)) { $script:DomeniaFixtureState = $null }

function Initialize-DomeniaFixtureTypes {
    # Loads System.DirectoryServices when present, compiles the C# 5 stand-ins once and locates the internal constructors.
    if ($null -ne $script:DomeniaFixtureState) { return $script:DomeniaFixtureState }
    try { Add-Type -AssemblyName System.DirectoryServices -ErrorAction Stop } catch { }
    if ($null -eq ('Domenia.Fixtures.PropertyValueCollectionDouble' -as [type])) {
        Add-Type -TypeDefinition $script:DomeniaFixtureSource -Language CSharp -ErrorAction Stop
    }
    $flags = [Reflection.BindingFlags]'NonPublic,Instance'
    $valuesCtor = $null; $propertiesCtor = $null; $propertiesAdd = $null; $resultCtor = $null; $secure = $null
    $valuesType = 'System.DirectoryServices.ResultPropertyValueCollection' -as [type]
    $propertiesType = 'System.DirectoryServices.ResultPropertyCollection' -as [type]
    $resultType = 'System.DirectoryServices.SearchResult' -as [type]
    $authType = 'System.DirectoryServices.AuthenticationTypes' -as [type]
    try {
        if ($null -ne $valuesType) { $valuesCtor = $valuesType.GetConstructor($flags,$null,[type[]]@([object[]]),$null) }
        if ($null -ne $propertiesType) {
            $propertiesCtor = $propertiesType.GetConstructor($flags,$null,[type[]]@(),$null)
            if ($null -ne $valuesType) { $propertiesAdd = $propertiesType.GetMethod('Add',$flags,$null,[type[]]@([string],$valuesType),$null) }
        }
        if (($null -ne $resultType) -and ($null -ne $authType)) {
            $resultCtor = $resultType.GetConstructor($flags,$null,[type[]]@([Net.NetworkCredential],$authType),$null)
            $secure = [Enum]::Parse($authType,'Secure')
        }
    } catch { $valuesCtor = $null; $propertiesCtor = $null; $propertiesAdd = $null; $resultCtor = $null }
    $genuine = (($null -ne $valuesCtor) -and ($null -ne $propertiesCtor) -and ($null -ne $propertiesAdd) -and ($null -ne $resultCtor))
    # Genuine IADsLargeInteger: the ADSI helper class, created in process (no bind, no request).
    $largeGenuine = $false
    if ($env:OS -eq 'Windows_NT') {
        try {
            $probe = New-Object -ComObject LargeInteger -ErrorAction Stop
            $largeGenuine = ($null -ne $probe)
        } catch { $largeGenuine = $false }
    }
    $limit = 'ResultPropertyValueCollection, ResultPropertyCollection et SearchResult reels ; PropertyValueCollection, PropertyCollection et SearchResultCollection emules.'
    if (-not $genuine) { $limit = 'System.DirectoryServices indisponible : toutes les collections AD sont emulees (memes classes de base).' }
    if ($largeGenuine) { $limit += ' IADsLargeInteger reel (classe ADSI LargeInteger).' } else { $limit += ' IADsLargeInteger emule (membres visibles par PowerShell, contrairement au reel).' }
    $script:DomeniaFixtureState = [pscustomobject]@{
        Genuine=$genuine;LargeIntegerGenuine=$largeGenuine;ValuesCtor=$valuesCtor;PropertiesCtor=$propertiesCtor;PropertiesAdd=$propertiesAdd;ResultCtor=$resultCtor;Secure=$secure;Limit=$limit
    }
    return $script:DomeniaFixtureState
}

function ConvertTo-DomeniaFixtureValues {
    # Normalises an attribute value into the list of its values. A byte[] or a string is ONE value:
    # Active Directory never returns a binary attribute as a list of bytes. $null means "no value".
    # A COM object (IADsLargeInteger) is one value too.
    param($Values)
    if ($null -eq $Values) { return ,([object[]]@()) }
    if (($Values -is [byte[]]) -or ($Values -is [string]) -or ($Values -is [__ComObject])) { return ,([object[]]@(,$Values)) }
    if (($Values -is [Collections.IEnumerable]) -and ($Values -isnot [Collections.IDictionary])) {
        $list = New-Object 'System.Collections.Generic.List[object]'
        foreach ($item in $Values) { $list.Add($item) }
        return ,$list.ToArray()
    }
    return ,([object[]]@(,$Values))
}

function New-DomeniaFixtureGuidBytes {
    # objectGUID as stored by Active Directory.
    param([Parameter(Mandatory=$true)][string]$Guid)
    $bytes = ([guid]$Guid).ToByteArray()
    return ,$bytes
}

function New-DomeniaFixtureSidBytes {
    # objectSid as stored by Active Directory, assembled byte by byte.
    param([Parameter(Mandatory=$true)][string]$Sid)
    $match = [regex]::Match($Sid,'^S-1-(\d+)((?:-\d+){1,15})$')
    if (-not $match.Success) { throw ('SID de fixture invalide : ' + $Sid) }
    if (-not [BitConverter]::IsLittleEndian) { throw 'Fixture SID prevue pour un processeur little-endian.' }
    $authority = [long]$match.Groups[1].Value
    $parts = @($match.Groups[2].Value.TrimStart('-').Split('-'))
    $bytes = New-Object byte[] (8 + 4 * $parts.Count)
    $bytes[0] = 1
    $bytes[1] = [byte]$parts.Count
    for ($i = 0; $i -lt 6; $i++) { $bytes[2 + $i] = [byte](($authority -shr (8 * (5 - $i))) -band 0xFF) }
    for ($j = 0; $j -lt $parts.Count; $j++) {
        $chunk = [BitConverter]::GetBytes([uint32]$parts[$j])
        [Array]::Copy($chunk,0,$bytes,(8 + 4 * $j),4)
    }
    return ,$bytes
}

function New-DomeniaFixtureFileTime {
    # AD large-integer time (100 ns since 1601-01-01 UTC) as DirectorySearcher returns it: an Int64.
    # 'Zero' and 'Never' (0x7FFFFFFFFFFFFFFF) are the two encodings of "no date".
    # Without -Utc, a fixed fictitious date (never the clock): every call gives the same value.
    param([datetime]$Utc=([datetime]::SpecifyKind([datetime]'2026-03-01T08:00:00',[DateTimeKind]::Utc)),[ValidateSet('Date','Zero','Never')][string]$Kind='Date')
    if ($Kind -eq 'Zero') { return [long]0 }
    if ($Kind -eq 'Never') { return [long]::MaxValue }
    $when = $Utc
    if ($when.Kind -eq [DateTimeKind]::Unspecified) { $when = [datetime]::SpecifyKind($when,[DateTimeKind]::Utc) }
    if ($when.Year -lt 1601) { throw 'Date de fixture anterieure a 1601 : aucun FILETIME possible.' }
    return [long]$when.ToFileTimeUtc()
}

function New-DomeniaFixtureLargeInteger {
    # IADsLargeInteger holding $Value, as DirectoryEntry returns a large-integer attribute: the genuine ADSI COM
    # object when available, the C# stand-in otherwise (or with -Emulated). See the limits at the top of this file.
    param([long]$Value,[switch]$Emulated)
    $state = Initialize-DomeniaFixtureTypes
    if (-not [BitConverter]::IsLittleEndian) { throw 'Fixture IADsLargeInteger prevue pour un processeur little-endian.' }
    $parts = [BitConverter]::GetBytes($Value)
    $low = [BitConverter]::ToInt32($parts,0)
    $high = [BitConverter]::ToInt32($parts,4)
    if ($state.LargeIntegerGenuine -and -not $Emulated) {
        $com = New-Object -ComObject LargeInteger
        $type = $com.GetType()
        # PowerShell sees no member on this object: the properties are written through IDispatch.
        [void]$type.InvokeMember('HighPart',[Reflection.BindingFlags]::SetProperty,$null,$com,@($high))
        [void]$type.InvokeMember('LowPart',[Reflection.BindingFlags]::SetProperty,$null,$com,@($low))
        return $com
    }
    return (New-Object Domenia.Fixtures.LargeIntegerDouble -ArgumentList $Value)
}

function ConvertFrom-DomeniaFixtureLargeInteger {
    # Test-side reading of an IADsLargeInteger (genuine or stand-in) through IDispatch / reflection, the only way
    # that works on the genuine object. Returns $null when the value is not a large integer.
    param($Value)
    if ($null -eq $Value) { return $null }
    try {
        $type = $Value.GetType()
        $high = [long]$type.InvokeMember('HighPart',[Reflection.BindingFlags]::GetProperty,$null,$Value,$null)
        $low = [long]$type.InvokeMember('LowPart',[Reflection.BindingFlags]::GetProperty,$null,$Value,$null)
        return [long](($high -shl 32) -bor ($low -band 0xFFFFFFFFL))
    } catch { return $null }
}

function Get-DomeniaFixtureLargeIntegerShapes {
    # Shapes of New-DomeniaFixtureCollection / New-DomeniaFixtureBag that come from DirectoryEntry:
    # an Int64 placed in them becomes an IADsLargeInteger.
    return @('PropertyValues','DirectoryProperties')
}

function New-DomeniaFixtureResultValues {
    # ResultPropertyValueCollection holding the given values (genuine type when available).
    param($Values)
    $state = Initialize-DomeniaFixtureTypes
    $items = ConvertTo-DomeniaFixtureValues $Values
    if ($state.Genuine) { $collection = $state.ValuesCtor.Invoke(@(,$items)); return ,$collection }
    $collection = New-Object Domenia.Fixtures.ResultPropertyValueCollectionDouble -ArgumentList @(,$items)
    return ,$collection
}

function New-DomeniaFixtureResultProperties {
    # ResultPropertyCollection (SearchResult.Properties) built from name -> value(s). A $null value leaves the
    # attribute out, as a search result does for an attribute without value.
    param([Collections.IDictionary]$Attributes,$Target=$null)
    $state = Initialize-DomeniaFixtureTypes
    $bag = $Target
    if ($null -eq $bag) {
        if ($state.Genuine) { $bag = $state.PropertiesCtor.Invoke(@()) } else { $bag = New-Object Domenia.Fixtures.ResultPropertyCollectionDouble }
    }
    if ($null -ne $Attributes) {
        foreach ($name in @($Attributes.Keys)) {
            $raw = $Attributes[$name]
            if ($null -eq $raw) { continue }
            $values = New-DomeniaFixtureResultValues $raw
            if ($state.Genuine) { [void]$state.PropertiesAdd.Invoke($bag,@([string]$name,$values)) }
            else { $bag.Add([string]$name,$values) }
        }
    }
    return ,$bag
}

function New-DomeniaFixtureSearchResult {
    # One SearchResult with its properties (adspath included), as returned by DirectorySearcher.FindOne/FindAll.
    param([Collections.IDictionary]$Attributes,[string]$Path='LDAP://dc01.example.invalid/CN=Fictif,DC=example,DC=invalid')
    $state = Initialize-DomeniaFixtureTypes
    $result = $null
    if ($state.Genuine) { $result = $state.ResultCtor.Invoke(@($null,$state.Secure)) } else { $result = New-Object Domenia.Fixtures.SearchResultDouble }
    $all = [ordered]@{}
    if ($null -ne $Attributes) { foreach ($name in @($Attributes.Keys)) { $all[[string]$name] = $Attributes[$name] } }
    $all['adspath'] = $Path
    [void](New-DomeniaFixtureResultProperties -Attributes $all -Target $result.Properties)
    return $result
}

function New-DomeniaFixtureSearchResults {
    # Emulated SearchResultCollection (FindAll) holding the given results, possibly only one.
    param($Results,[string[]]$PropertiesLoaded=@())
    [void](Initialize-DomeniaFixtureTypes)
    $items = ConvertTo-DomeniaFixtureValues $Results
    $collection = New-Object Domenia.Fixtures.SearchResultCollectionDouble -ArgumentList @($items,[string[]]$PropertiesLoaded)
    return ,$collection
}

function New-DomeniaFixturePropertyValues {
    # Emulated PropertyValueCollection (DirectoryEntry.Properties[name]). DirectoryEntry never returns an Int64:
    # each Int64 value (large-integer syntax in these fixtures) is stored as an IADsLargeInteger.
    param([string]$Name='value',$Values)
    [void](Initialize-DomeniaFixtureTypes)
    $items = ConvertTo-DomeniaFixtureValues $Values
    for ($i = 0; $i -lt $items.Count; $i++) {
        if ($items[$i] -is [long]) { $items[$i] = New-DomeniaFixtureLargeInteger ([long]$items[$i]) }
    }
    $collection = New-Object Domenia.Fixtures.PropertyValueCollectionDouble -ArgumentList @($Name,$items)
    return ,$collection
}

function New-DomeniaFixtureDirectoryProperties {
    # Emulated PropertyCollection (DirectoryEntry.Properties) built from name -> value(s); Int64 values become
    # IADsLargeInteger (see New-DomeniaFixturePropertyValues).
    param([Collections.IDictionary]$Attributes)
    [void](Initialize-DomeniaFixtureTypes)
    $bag = New-Object Domenia.Fixtures.PropertyCollectionDouble
    if ($null -ne $Attributes) {
        foreach ($name in @($Attributes.Keys)) {
            $raw = $Attributes[$name]
            if ($null -eq $raw) { continue }
            $bag.Add([string]$name,(New-DomeniaFixturePropertyValues -Name ([string]$name) -Values $raw))
        }
    }
    return ,$bag
}

function New-DomeniaFixtureAccessRules {
    # ACEs as ActiveDirectorySecurity.GetAccessRules returns them: an AuthorizationRuleCollection
    # (ReadOnlyCollectionBase, not IList), built in memory from a security descriptor that is never written.
    # Without System.DirectoryServices, the same properties are carried by plain objects in a stand-in collection.
    param([string[]]$Sids=@(),[string]$Rights='ReadProperty',[ValidateSet('Allow','Deny')][string]$Type='Allow')
    [void](Initialize-DomeniaFixtureTypes)
    $securityType = 'System.DirectoryServices.ActiveDirectorySecurity' -as [type]
    if ($null -ne $securityType) {
        $descriptor = New-Object System.DirectoryServices.ActiveDirectorySecurity
        foreach ($sid in @($Sids)) {
            $identity = New-Object Security.Principal.SecurityIdentifier -ArgumentList $sid
            $rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule -ArgumentList @($identity,[System.DirectoryServices.ActiveDirectoryRights]$Rights,[Security.AccessControl.AccessControlType]$Type)
            $descriptor.AddAccessRule($rule)
        }
        $rules = $descriptor.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])
        return ,$rules
    }
    $items = New-Object 'System.Collections.Generic.List[object]'
    foreach ($sid in @($Sids)) {
        $items.Add([pscustomobject]@{IdentityReference=$sid;ActiveDirectoryRights=$Rights;AccessControlType=$Type;ObjectType=[guid]::Empty;InheritanceType='None';IsInherited=$false})
    }
    $collection = New-Object Domenia.Fixtures.ResultPropertyValueCollectionDouble -ArgumentList @(,$items.ToArray())
    return ,$collection
}

function New-DomeniaFixtureUnrolledBytes {
    # What PowerShell makes of a byte[] that crossed a pipeline without the unary comma: boxed bytes in an object[].
    param([byte[]]$Bytes)
    $unrolled = @($Bytes | ForEach-Object { $_ })
    return ,$unrolled
}

function Get-DomeniaFixtureShapes {
    # Containers a single AD value may arrive in.
    return @('Array','ArrayList','List','ResultValues','PropertyValues')
}

function New-DomeniaFixtureCollection {
    # The same values in one of the containers listed by Get-DomeniaFixtureShapes.
    param([Parameter(Mandatory=$true)][ValidateSet('Array','ArrayList','List','ResultValues','PropertyValues')][string]$Shape,$Values)
    $items = ConvertTo-DomeniaFixtureValues $Values
    switch ($Shape) {
        'Array' { return ,$items }
        'ArrayList' { $list = New-Object System.Collections.ArrayList; foreach ($item in $items) { [void]$list.Add($item) }; return ,$list }
        'List' { $generic = New-Object 'System.Collections.Generic.List[object]'; foreach ($item in $items) { $generic.Add($item) }; return ,$generic }
        'ResultValues' { $values = New-DomeniaFixtureResultValues $items; return ,$values }
        default { $values = New-DomeniaFixturePropertyValues -Values $items; return ,$values }
    }
}

function New-DomeniaFixtureUserAttributes {
    # Fictitious user as Active Directory returns it: binary identifiers, Int32 flags, Int64 FILETIME values,
    # a multi-valued attribute holding a single value, GeneralizedTime as an unspecified-kind DateTime in UTC.
    param(
        [datetime]$NowUtc=[datetime]::SpecifyKind([datetime]'2026-03-01T08:00:00',[DateTimeKind]::Utc),
        [string]$Guid='6f9619ff-8b86-d011-b42d-00c04fc964ff',
        [string]$Sid='S-1-5-21-1004336348-1177238915-682003330-1104',
        [int]$UserAccountControl=512,
        [ValidateSet('Date','Zero','Never')][string]$PwdLastSet='Zero'
    )
    $attributes = [ordered]@{}
    $attributes['objectGUID'] = (New-DomeniaFixtureGuidBytes $Guid)
    $attributes['objectSid'] = (New-DomeniaFixtureSidBytes $Sid)
    $attributes['sAMAccountName'] = 'jdemo'
    $attributes['displayName'] = 'Jeanne Demo'
    $attributes['userPrincipalName'] = 'jdemo@example.invalid'
    $attributes['distinguishedName'] = 'CN=Jeanne Demo,OU=Support,DC=example,DC=invalid'
    $attributes['department'] = 'Support'
    $attributes['manager'] = 'CN=Marc Fictif,OU=Support,DC=example,DC=invalid'
    $attributes['userAccountControl'] = [int]$UserAccountControl
    $attributes['msDS-User-Account-Control-Computed'] = [int]0
    $attributes['primaryGroupID'] = [int]513
    $attributes['pwdLastSet'] = (New-DomeniaFixtureFileTime -Utc $NowUtc.AddDays(-10) -Kind $PwdLastSet)
    $attributes['lastLogonTimestamp'] = (New-DomeniaFixtureFileTime -Utc $NowUtc.AddDays(-2))
    $attributes['accountExpires'] = (New-DomeniaFixtureFileTime -Kind Never)
    $attributes['lockoutTime'] = (New-DomeniaFixtureFileTime -Kind Zero)
    $attributes['memberOf'] = @('CN=Support N1,OU=Groupes,DC=example,DC=invalid')
    $attributes['whenCreated'] = [datetime]::SpecifyKind($NowUtc.AddYears(-1),[DateTimeKind]::Unspecified)
    # Fictitious single-valued binary attribute holding ONE byte (no standard AD attribute has this shape on every forest).
    $attributes['msDS-OneByte'] = [byte[]]@(42)
    return $attributes
}

function New-DomeniaFixtureDomainPolicyAttributes {
    # Fictitious domain password policy as the domain head returns it: durations are negative Int64 intervals
    # (100 ns units), counters are Int32.
    return [ordered]@{
        minPwdLength=[int]12;pwdHistoryLength=[int]24;pwdProperties=[int]1;lockoutThreshold=[int]5
        maxPwdAge=[long]-36288000000000;lockoutDuration=[long]-18000000000;lockOutObservationWindow=[long]-18000000000
        distinguishedName='DC=example,DC=invalid'
    }
}

function New-DomeniaFixtureBag {
    # The same attributes (the fictitious user by default) in the property bags a rule may receive:
    #   Hashtable           name -> object[] of values (what a worker copies out of a search result)
    #   Scalar              name -> the single value itself (byte[] kept whole), lists for multi-valued attributes
    #   ResultProperties    SearchResult.Properties (genuine type when available): large integers are Int64
    #   DirectoryProperties DirectoryEntry.Properties (emulated): large integers are IADsLargeInteger, never Int64
    param([Parameter(Mandatory=$true)][ValidateSet('Hashtable','Scalar','ResultProperties','DirectoryProperties')][string]$Shape,[Collections.IDictionary]$Attributes)
    if ($null -eq $Attributes) { $Attributes = New-DomeniaFixtureUserAttributes }
    switch ($Shape) {
        'Hashtable' {
            $bag = @{}
            foreach ($name in @($Attributes.Keys)) { if ($null -ne $Attributes[$name]) { $bag[[string]$name] = (ConvertTo-DomeniaFixtureValues $Attributes[$name]) } }
            return ,$bag
        }
        'Scalar' {
            $bag = @{}
            foreach ($name in @($Attributes.Keys)) {
                $value = $Attributes[$name]
                if ($null -eq $value) { continue }
                $values = ConvertTo-DomeniaFixtureValues $value
                if ($values.Count -eq 1) { $bag[[string]$name] = $values[0] } else { $bag[[string]$name] = $values }
            }
            return ,$bag
        }
        'ResultProperties' { $bag = (New-DomeniaFixtureSearchResult -Attributes $Attributes).Properties; return ,$bag }
        default { $bag = New-DomeniaFixtureDirectoryProperties -Attributes $Attributes; return ,$bag }
    }
}

function New-DomeniaFixtureReplMetadata {
    # One msDS-ReplAttributeMetaData value (DS_REPL_ATTR_META_DATA XML fragment) for one attribute, as a controller
    # returns it: a string, ended by a NUL character like the values read through LDAP.
    param([Parameter(Mandatory=$true)][string]$Attribute,[int]$Version=1,[datetime]$ChangedUtc=([datetime]::SpecifyKind([datetime]'2025-11-02T09:15:00',[DateTimeKind]::Utc)),[string]$Dc='DC01',[long]$LocalUsn=23456,[long]$OriginatingUsn=12345)
    $stamp = [datetime]::SpecifyKind($ChangedUtc,[DateTimeKind]::Utc).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'",[Globalization.CultureInfo]::InvariantCulture)
    $lines = @(
        '<DS_REPL_ATTR_META_DATA>',
        ("`t<pszAttributeName>" + $Attribute + '</pszAttributeName>'),
        ("`t<dwVersion>" + $Version + '</dwVersion>'),
        ("`t<ftimeLastOriginatingChange>" + $stamp + '</ftimeLastOriginatingChange>'),
        "`t<uuidLastOriginatingDsaInvocationID>0a1b2c3d-1111-2222-3333-444455556666</uuidLastOriginatingDsaInvocationID>",
        ("`t<usnOriginatingChange>" + $OriginatingUsn + '</usnOriginatingChange>'),
        ("`t<usnLocalChange>" + $LocalUsn + '</usnLocalChange>'),
        ("`t<pszLastOriginatingDsaDN>CN=NTDS Settings,CN=" + $Dc + ',CN=Servers,CN=Site-Demo,CN=Sites,CN=Configuration,DC=example,DC=invalid</pszLastOriginatingDsaDN>'),
        '</DS_REPL_ATTR_META_DATA>'
    )
    return (($lines -join "`n") + [string][char]0)
}

function New-DomeniaFixtureRow {
    # A Domenia result row whose Guid and Sid keep the representation chosen by the test.
    param($Guid,$Sid='',[string]$Type='Utilisateur',[string]$Name='Jeanne Demo',[string]$Login='jdemo',[string]$Dn='CN=Jeanne Demo,OU=Support,DC=example,DC=invalid')
    return [pscustomobject]@{Type=$Type;Name=$Name;Login=$Login;DN=$Dn;Guid=$Guid;Sid=$Sid}
}

# ---------------------------------------------------------------- suites lot API (D004/D008 wiring suites)
# Kept next to the API above: Test-DomeniaWiringSuites, Test-DomeniaFaults and Test-DomeniaRegressions use them.
# Lost when the add/add conflict of this file was settled in favour of master (merge 0ba63e1); restored from 415f157.

function ConvertTo-DomeniaFixtureFileTime {
    # AD time attributes (lastLogonTimestamp, pwdLastSet, accountExpires) are 100 ns ticks since 1601 UTC.
    param([Parameter(Mandatory=$true)][datetime]$Utc)
    return [long]$Utc.ToUniversalTime().ToFileTimeUtc()
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

function New-DomeniaFixtureRangedDirectoryEntry {
    # DirectoryEntry stand-in for the ranged reads of Get-WAllProperties, unlike New-DomeniaFixtureDirectoryEntry
    # which only answers a flat Properties bag. It answers the way a directory answers a multi-valued attribute:
    #   - a plain request for an attribute that fits is cached under its own name; a plain request for one that
    #     does not fit is cached truncated, under 'attribute;range=0-1499', which is the trap the product reads;
    #   - a requested range that does not cover the rest of the attribute is cached under that very key;
    #   - a range that covers the rest is cached under its own name when it starts at 0, and as
    #     'attribute;range=start-*' otherwise, which is how the server closes a ranged read;
    #   - the last gather of an attribute replaces the previous ones, so the caller sees one key per attribute.
    # RefreshCache(string[]) records every name it was asked for: one flat list in Refreshed, one entry per call
    # in Batches, so a test can tell what the product asked for, and in which order.
    param([hashtable]$Attributes=@{})
    if($null -eq ('DomeniaFixture.DirectoryEntryRangedDouble' -as [type])){
        Add-Type -Language CSharp -TypeDefinition @'
namespace DomeniaFixture
{
    using System;
    using System.Collections;
    using System.Collections.Generic;
    using System.Globalization;

    public sealed class DirectoryRangedProperties
    {
        private readonly Hashtable values;
        public DirectoryRangedProperties(Hashtable values) { this.values = values; }
        public object this[string name] { get { return values.Contains(name) ? values[name] : null; } }
        public bool Contains(string name) { return values.Contains(name); }
        public string[] PropertyNames
        {
            get
            {
                string[] names = new string[values.Keys.Count];
                values.Keys.CopyTo(names, 0);
                return names;
            }
        }
    }

    public sealed class DirectoryEntryRangedDouble
    {
        private const int MaxValuesPerRead = 1500;
        private readonly Hashtable source;
        private readonly Hashtable cached = new Hashtable(StringComparer.OrdinalIgnoreCase);
        private readonly List<string> refreshed = new List<string>();
        private readonly List<string> batches = new List<string>();
        public DirectoryEntryRangedDouble(Hashtable source) { this.source = source; }
        public DirectoryRangedProperties Properties { get { return new DirectoryRangedProperties(cached); } }
        public string[] Refreshed { get { return refreshed.ToArray(); } }
        public string[] Batches { get { return batches.ToArray(); } }
        public void RefreshCache(string[] names)
        {
            if (names == null) { return; }
            batches.Add(string.Join(",", names));
            foreach (string name in names)
            {
                refreshed.Add(name);
                int marker = name.IndexOf(";range=");
                if (marker < 0)
                {
                    if (!source.Contains(name)) { continue; }
                    IList whole = source[name] as IList;
                    if (whole == null) { continue; }
                    if (whole.Count > MaxValuesPerRead) { cached[name + ";range=0-" + (MaxValuesPerRead - 1).ToString(CultureInfo.InvariantCulture)] = Slice(whole, 0, MaxValuesPerRead - 1); }
                    else { cached[name] = whole; }
                    continue;
                }
                string attribute = name.Substring(0, marker);
                if (!source.Contains(attribute)) { continue; }
                IList values = source[attribute] as IList;
                if (values == null) { continue; }
                string spec = name.Substring(marker + 7);
                int dash = spec.IndexOf('-');
                if (dash < 0) { continue; }
                int start = int.Parse(spec.Substring(0, dash), CultureInfo.InvariantCulture);
                string endText = spec.Substring(dash + 1);
                int end = endText == "*" ? int.MaxValue : int.Parse(endText, CultureInfo.InvariantCulture);
                cached.Remove(attribute);
                foreach (string stale in StaleKeys(attribute)) { cached.Remove(stale); }
                if (start >= values.Count) { cached[attribute + ";range=" + start + "-*"] = new ArrayList(); continue; }
                if (end >= values.Count - 1)
                {
                    if (start == 0) { cached[attribute] = values; }
                    else { cached[attribute + ";range=" + start + "-*"] = Slice(values, start, values.Count - 1); }
                    continue;
                }
                cached[name] = Slice(values, start, end);
            }
        }
        private static ArrayList Slice(IList values, int start, int end)
        {
            ArrayList slice = new ArrayList();
            int stop = end >= values.Count - 1 ? values.Count - 1 : end;
            for (int i = start; i <= stop; i++) { slice.Add(values[i]); }
            return slice;
        }
        private List<string> StaleKeys(string attribute)
        {
            List<string> keys = new List<string>();
            foreach (DictionaryEntry entry in cached)
            {
                string key = (string)entry.Key;
                if (key.StartsWith(attribute + ";range=", StringComparison.OrdinalIgnoreCase)) { keys.Add(key); }
            }
            return keys;
        }
    }
}
'@
    }
    # Les valeurs traversent PowerShell emballees en PSObject : la table .NET recoit l'objet deballe, sinon
    # le double ne voit qu'un wrapper et ne peut plus compter les valeurs.
    $source=New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
    foreach($name in @($Attributes.Keys)){
        $value=$Attributes[$name]
        if($null -ne $value){$value=$value.psobject.BaseObject}
        [void]$source.Add([string]$name,$value)
    }
    return New-Object DomeniaFixture.DirectoryEntryRangedDouble -ArgumentList @(,$source)
}
