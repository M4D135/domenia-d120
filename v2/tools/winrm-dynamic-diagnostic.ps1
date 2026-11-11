# Windows PowerShell 5.1, hosted CI runner only. Replays the product's late-bound C# calls to WSMan.Automation against
# localhost with the preinstalled .NET SDK, in a temporary folder outside the repository, with no package source.
# Nothing is changed in WinRM; only stages, exception types, HRESULTs and WSManFault codes are written.
param([Parameter(Mandatory = $true)][string]$WorkDir)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
$project = @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <NuGetAudit>false</NuGetAudit>
  </PropertyGroup>
</Project>
'@
$config = @'
<?xml version="1.0" encoding="utf-8"?>
<configuration><packageSources><clear /></packageSources></configuration>
'@
$program = @'
using System.Runtime.InteropServices;
using System.Xml.Linq;

const string Url = "http://localhost:5985/wsman";
const string Resource = "http://schemas.microsoft.com/wbem/wsman/1/wmi/root/cimv2/*";
const string Wql = "http://schemas.microsoft.com/wbem/wsman/1/WQL";
const string Query = "SELECT Caption, Version, BuildNumber FROM Win32_OperatingSystem";
const int Negotiate = 0x20000, Kerberos = 0x80000;

Trial("V1 product call, options null, Negotiate", Negotiate, true);
Trial("V2 two arguments, Negotiate", Negotiate, false);
Trial("V3 product call, options null, Kerberos", Kerberos, true);
Trial("V4 two arguments, Kerberos", Kerberos, false);

// A refused connection, as on a workstation without a WinRM listener (bench of 11/11/2026: Identify failed in 0x80338012
// after about 4.2 s). Port 5999 has no listener on the runner; nothing is changed. The product reads on thread-pool threads
// while its STA main thread is blocked: reproduce that and bound each trial so a blocked call is reported, not waited on.
const string Closed = "http://localhost:5999/wsman";
var sta = new Thread(() =>
{
    Timed("C1 closed port, Enumerate first, Timeout 10 s", Closed, 10000, false, 1);
    Timed("C2 closed port, Identify then Enumerate, Timeout 10 s", Closed, 10000, true, 1);
    Timed("C3 closed port, Enumerate first, Timeout 3 s", Closed, 3000, false, 1);
    Timed("C4 closed port, two Enumerate on one session, Timeout 10 s", Closed, 10000, false, 2);
    Timed("C5 open port, Identify then Enumerate, Timeout 10 s (Negotiate)", Url, 10000, true, 1, Negotiate);
});
sta.SetApartmentState(ApartmentState.STA);
sta.Start();
sta.Join();
Environment.Exit(0);
return 0;

static void Timed(string name, string url, int timeoutMs, bool identify, int enumerations, int flags = Kerberos)
{
    var watch = System.Diagnostics.Stopwatch.StartNew();
    var steps = new System.Collections.Concurrent.ConcurrentQueue<string>();
    var stage = "Activate";
    var work = Task.Run(() =>
    {
        object? automation = null, connection = null;
        try
        {
            automation = Activator.CreateInstance(Type.GetTypeFromProgID("WSMan.Automation", throwOnError: true)!)!;
            stage = "CreateSession";
            connection = ((dynamic)automation).CreateSession(url, flags);
            ((dynamic)connection!).Timeout = timeoutMs;
            steps.Enqueue("CreateSession@" + watch.ElapsedMilliseconds);
            if (identify) { stage = "Identify"; _ = (string)((dynamic)connection).Identify(0); steps.Enqueue("Identify@" + watch.ElapsedMilliseconds); }
            for (var i = 0; i < enumerations; i++)
            {
                try
                {
                    stage = "Enumerate" + i;
                    object enumerator = ((dynamic)connection).Enumerate(Resource, Query, Wql, 0);
                    steps.Enqueue("Enumerate" + i + "@" + watch.ElapsedMilliseconds);
                    stage = "AtEndOfStream" + i;
                    bool end = ((dynamic)enumerator).AtEndOfStream;
                    steps.Enqueue("AtEndOfStream" + i + "=" + end + "@" + watch.ElapsedMilliseconds);
                    if (!end) { stage = "ReadItem" + i; _ = (string)((dynamic)enumerator).ReadItem(); steps.Enqueue("ReadItem" + i + "@" + watch.ElapsedMilliseconds); }
                    Marshal.FinalReleaseComObject(enumerator);
                }
                catch (Exception ex) when (enumerations > 1 && i == 0)
                { steps.Enqueue("Failed:" + stage + "@" + watch.ElapsedMilliseconds + " " + Chain(ex) + " | " + FaultOf(connection)); }
            }
            return "OK";
        }
        catch (Exception ex) { return "FAIL stage=" + stage + "@" + watch.ElapsedMilliseconds + " " + Chain(ex) + " | " + FaultOf(connection); }
        finally
        {
            foreach (var item in new[] { connection, automation }) { if (item is not null && Marshal.IsComObject(item)) { Marshal.FinalReleaseComObject(item); } }
        }
    });
    var outcome = work.Wait(45000) ? work.Result : "HUNG stage=" + stage + " after 45000 ms";
    Console.WriteLine(name + ": " + outcome + " | steps " + string.Join(", ", steps) + " | thread apartment of caller " + Thread.CurrentThread.GetApartmentState());
}

static string FaultOf(object? connection)
{
    if (connection is null) { return "no session"; }
    try { string? xml = ((dynamic)connection).Error; return string.IsNullOrEmpty(xml) ? "empty" : FaultCode(xml); }
    catch (Exception inner) { return "Error read throws " + Chain(inner); }
}

static void Trial(string name, int flags, bool passOptions)
{
    var stage = "Activate";
    object? automation = null, connection = null, enumerator = null;
    var items = 0;
    string? root = null;
    try
    {
        automation = Activator.CreateInstance(Type.GetTypeFromProgID("WSMan.Automation", throwOnError: true)!)!;
        stage = "CreateSession";
        object? options = null;
        connection = passOptions ? ((dynamic)automation).CreateSession(Url, flags, options) : ((dynamic)automation).CreateSession(Url, flags);
        stage = "Timeout";
        ((dynamic)connection!).Timeout = 10000;
        stage = "Enumerate";
        enumerator = ((dynamic)connection).Enumerate(Resource, Query, Wql, 0);
        while (items < 3)
        {
            stage = "Timeout (loop)";
            ((dynamic)connection).Timeout = 9000;
            stage = "AtEndOfStream";
            if (((dynamic)enumerator!).AtEndOfStream) { break; }
            stage = "ReadItem";
            string xml = ((dynamic)enumerator).ReadItem();
            items++;
            root ??= XElement.Parse(xml).Name.ToString();
        }
        Console.WriteLine(name + ": OK items=" + items + " root=" + root);
    }
    catch (Exception ex)
    {
        var error = "no session";
        if (connection is not null)
        {
            try { string? xml = ((dynamic)connection).Error; error = string.IsNullOrEmpty(xml) ? "empty" : FaultCode(xml); }
            catch (Exception inner) { error = "Error read throws " + Chain(inner); }
        }
        Console.WriteLine(name + ": FAIL stage=" + stage + " " + Chain(ex) + " | " + error);
    }
    finally
    {
        foreach (var item in new[] { enumerator, connection, automation }) { if (item is not null && Marshal.IsComObject(item)) { Marshal.FinalReleaseComObject(item); } }
    }
}

static string Chain(Exception? e)
{
    var parts = new List<string>();
    for (; e is not null; e = e.InnerException) { parts.Add(e.GetType().FullName + " 0x" + e.HResult.ToString("X8")); }
    return string.Join(" <- ", parts);
}

static string FaultCode(string xml)
{
    try { return "WSManFault Code=" + (string?)XElement.Parse(xml).DescendantsAndSelf().FirstOrDefault(e => e.Name.LocalName == "WSManFault")?.Attribute("Code"); }
    catch (Exception ex) { return "fault unreadable " + ex.GetType().Name; }
}
'@
$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $WorkDir 'WinRmDynamic.csproj'), $project, $utf8)
[IO.File]::WriteAllText((Join-Path $WorkDir 'nuget.config'), $config, $utf8)
[IO.File]::WriteAllText((Join-Path $WorkDir 'Program.cs'), $program, $utf8)
& dotnet --list-sdks
Push-Location $WorkDir
try {
    & dotnet run --configuration Release
    if ($LASTEXITCODE -ne 0) { Write-Output ('dotnet run exit ' + $LASTEXITCODE) }
} finally { Pop-Location }
exit 0
