#requires -Version 5.1
# Development-only deterministic build of the reviewed Query source vendored in this repository.
# References and Roslyn are supplied explicitly; nothing is downloaded by this tool or at runtime.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ReferenceDirectory,[string]$OutputDirectory='',[string]$CompilerDirectory='')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
if(-not $OutputDirectory){$OutputDirectory=Join-Path $root 'wad/modules'}
# Windows PowerShell hosts can use the compiler executable without loading Roslyn dependencies into their CLR.
$csc=if($CompilerDirectory){Join-Path $CompilerDirectory 'csc.exe'}else{''}
if($csc -and [IO.File]::Exists($csc)){
    [void][IO.Directory]::CreateDirectory($OutputDirectory)
    $temporary=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-build-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($temporary)
    try{
        $infoPath=Join-Path $temporary 'AssemblyInfo.cs'
        [IO.File]::WriteAllText($infoPath,'[assembly:System.Reflection.AssemblyVersion("0.1.1.1")][assembly:System.Reflection.AssemblyInformationalVersion("0.1.1-domenia.1")][assembly:System.Runtime.Versioning.TargetFramework(".NETFramework,Version=v4.7.2")]',[Text.UTF8Encoding]::new($false))
        $path=Join-Path $OutputDirectory 'M4D.Admin.Common.Query.dll'
        $arguments=@('/nologo','/noconfig','/nostdlib+','/target:library','/langversion:5','/optimize+','/deterministic+','/warnaserror+','/utf8output',('/out:'+$path),('/pathmap:'+$temporary+'=/_/build,'+$root+'=/_/domenia'))
        foreach($name in @('mscorlib.dll','System.dll','System.Core.dll')){
            $reference=Join-Path $ReferenceDirectory $name
            if(-not [IO.File]::Exists($reference)){throw ('Framework reference missing: '+$reference)}
            $arguments+=('/reference:'+$reference)
        }
        $sources=@((Join-Path $root 'vendor/m4d-admin-common/src/Query/QueryEngine.cs'))
        $arguments+=@($infoPath)+$sources
        $compilerOutput=& $csc @arguments 2>&1
        if($LASTEXITCODE -ne 0){throw ('Compilation failed: '+($compilerOutput -join [Environment]::NewLine))}
        $sourceHashes=@($sources|ForEach-Object{[pscustomobject]@{Name=[IO.Path]::GetFileName($_);SHA256=(Get-FileHash $_ -Algorithm SHA256).Hash}})
        [pscustomobject]@{Path=$path;SHA256=(Get-FileHash $path -Algorithm SHA256).Hash;Sources=$sourceHashes;TargetFramework='net472';Deterministic=$true;CompilerSHA256=(Get-FileHash $csc -Algorithm SHA256).Hash;CompilerVersion=[Diagnostics.FileVersionInfo]::GetVersionInfo($csc).FileVersion;PowerShell=$PSVersionTable.PSVersion.ToString()}|ConvertTo-Json -Depth 5
    }finally{Remove-Item -LiteralPath $temporary -Recurse -Force}
    return
}

if(-not $CompilerDirectory){$CompilerDirectory=$PSHOME}
foreach($name in @('Microsoft.CodeAnalysis.dll','Microsoft.CodeAnalysis.CSharp.dll')){
 $path=Join-Path $CompilerDirectory $name
 if(-not [IO.File]::Exists($path)){throw ('Roslyn unavailable: '+$name+'. Use PowerShell 7.4+ or supply compatible compiler assemblies.')}
 Add-Type -Path $path
}
$references=@('mscorlib.dll','System.dll','System.Core.dll')|ForEach-Object{
 $path=Join-Path $ReferenceDirectory $_
 if(-not [IO.File]::Exists($path)){throw ('Framework reference missing: '+$_)}
 [Microsoft.CodeAnalysis.MetadataReference]::CreateFromFile($path)
}
$source=Join-Path $root 'vendor/m4d-admin-common/src/Query/QueryEngine.cs'
$parse=[Microsoft.CodeAnalysis.CSharp.CSharpParseOptions]::Default.WithLanguageVersion([Microsoft.CodeAnalysis.CSharp.LanguageVersion]::CSharp5)
$options=[Microsoft.CodeAnalysis.CSharp.CSharpCompilationOptions]::new([Microsoft.CodeAnalysis.OutputKind]::DynamicallyLinkedLibrary).WithOptimizationLevel([Microsoft.CodeAnalysis.OptimizationLevel]::Release).WithDeterministic($true)
$trees=[Collections.Generic.List[Microsoft.CodeAnalysis.SyntaxTree]]::new()
$info='[assembly:System.Reflection.AssemblyVersion("0.1.1.1")][assembly:System.Reflection.AssemblyInformationalVersion("0.1.1-domenia.1")][assembly:System.Runtime.Versioning.TargetFramework(".NETFramework,Version=v4.7.2")]'
$trees.Add([Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText($info,$parse,'AssemblyInfo.cs',[Text.Encoding]::UTF8))
$trees.Add([Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText([IO.File]::ReadAllText($source),$parse,'QueryEngine.cs',[Text.Encoding]::UTF8))
$compilation=[Microsoft.CodeAnalysis.CSharp.CSharpCompilation]::Create('M4D.Admin.Common.Query',$trees.ToArray(),[Microsoft.CodeAnalysis.MetadataReference[]]$references,$options)
$stream=[IO.MemoryStream]::new()
try{
 $result=$compilation.Emit($stream)
 if(-not $result.Success -or @($result.Diagnostics|Where-Object{$_.Severity -in @('Error','Warning')}).Count){throw (($result.Diagnostics|ForEach-Object{$_.ToString()}) -join "`n")}
 [void][IO.Directory]::CreateDirectory($OutputDirectory)
 $path=Join-Path $OutputDirectory 'M4D.Admin.Common.Query.dll';[IO.File]::WriteAllBytes($path,$stream.ToArray())
 [pscustomobject]@{Path=$path;SHA256=(Get-FileHash $path -Algorithm SHA256).Hash;SourceSHA256=(Get-FileHash $source -Algorithm SHA256).Hash;SourceHashFormat='SHA256 of QueryEngine.cs file bytes';Version='0.1.1-domenia.1';TargetFramework='net472';CompilerSHA256=(Get-FileHash (Join-Path $CompilerDirectory 'Microsoft.CodeAnalysis.CSharp.dll') -Algorithm SHA256).Hash;CompilerVersion=[Microsoft.CodeAnalysis.CSharp.CSharpCompilation].Assembly.GetName().Version.ToString();PowerShell=$PSVersionTable.PSVersion.ToString()}|ConvertTo-Json
}finally{$stream.Dispose()}
