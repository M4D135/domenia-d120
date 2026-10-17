#requires -Version 5.1
# Build only: reuse an explicitly provided net472 reference pack; never download at runtime.
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
        [IO.File]::WriteAllText($infoPath,'[assembly:System.Reflection.AssemblyVersion("1.0.0.0")][assembly:System.Runtime.Versioning.TargetFramework(".NETFramework,Version=v4.7.2")]',[Text.UTF8Encoding]::new($false))
        $path=Join-Path $OutputDirectory 'Domenia.Native.dll'
        $arguments=@('/nologo','/noconfig','/nostdlib+','/target:library','/langversion:5','/optimize+','/deterministic+','/warnaserror+','/utf8output',('/out:'+$path),('/pathmap:'+$temporary+'=/_/build,'+$root+'=/_/domenia'))
        foreach($name in @('mscorlib.dll','System.dll','System.Core.dll','System.Runtime.Serialization.dll','System.Xml.dll')){
            $reference=Join-Path $ReferenceDirectory $name
            if(-not [IO.File]::Exists($reference)){throw ('Framework reference missing: '+$reference)}
            $arguments+=('/reference:'+$reference)
        }
        $sources=@(Get-ChildItem (Join-Path $root 'native') -Filter '*.cs' | Sort-Object Name | ForEach-Object {$_.FullName})
        $arguments+=@($infoPath)+$sources
        $compilerOutput=& $csc @arguments 2>&1
        if($LASTEXITCODE -ne 0){throw ('Compilation failed: '+($compilerOutput -join [Environment]::NewLine))}
        $sourceHashes=@($sources|ForEach-Object{[pscustomobject]@{Name=[IO.Path]::GetFileName($_);SHA256=(Get-FileHash $_ -Algorithm SHA256).Hash}})
        [pscustomobject]@{Path=$path;SHA256=(Get-FileHash $path -Algorithm SHA256).Hash;Sources=$sourceHashes;TargetFramework='net472';Deterministic=$true;CompilerSHA256=(Get-FileHash $csc -Algorithm SHA256).Hash;CompilerVersion=[Diagnostics.FileVersionInfo]::GetVersionInfo($csc).FileVersion;PowerShell=$PSVersionTable.PSVersion.ToString()}|ConvertTo-Json -Depth 5
    }finally{Remove-Item -LiteralPath $temporary -Recurse -Force}
    return
}

[void][IO.Directory]::CreateDirectory($OutputDirectory)
# Compilation is optional development work. PROD assembly needs only PowerShell 5.1.
# PowerShell 7 supplies Roslyn; on Windows PowerShell provide a Framework-compatible compiler.
if(-not $CompilerDirectory){$CompilerDirectory=$PSHOME}
foreach($name in @('Microsoft.CodeAnalysis.dll','Microsoft.CodeAnalysis.CSharp.dll')){
    $compiler=Join-Path $CompilerDirectory $name
    if(-not [IO.File]::Exists($compiler)){throw 'Roslyn compiler unavailable. Run this optional build tool in PowerShell 7.4+, or pass -CompilerDirectory with Roslyn assemblies compatible with the current .NET runtime. No download is performed.'}
    Add-Type -Path $compiler
}
$parse=[Microsoft.CodeAnalysis.CSharp.CSharpParseOptions]::Default.WithLanguageVersion([Microsoft.CodeAnalysis.CSharp.LanguageVersion]::CSharp5)
$options=[Microsoft.CodeAnalysis.CSharp.CSharpCompilationOptions]::new([Microsoft.CodeAnalysis.OutputKind]::DynamicallyLinkedLibrary).WithOptimizationLevel([Microsoft.CodeAnalysis.OptimizationLevel]::Release).WithDeterministic($true)
$references=@('mscorlib.dll','System.dll','System.Core.dll','System.Runtime.Serialization.dll','System.Xml.dll')|ForEach-Object{[Microsoft.CodeAnalysis.MetadataReference]::CreateFromFile((Join-Path $ReferenceDirectory $_))}
$trees=[Collections.Generic.List[Microsoft.CodeAnalysis.SyntaxTree]]::new()
$info='[assembly:System.Reflection.AssemblyVersion("1.0.0.0")][assembly:System.Runtime.Versioning.TargetFramework(".NETFramework,Version=v4.7.2")]'
$trees.Add([Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText($info,$parse,'AssemblyInfo.cs',[Text.Encoding]::UTF8))
foreach($file in @(Get-ChildItem (Join-Path $root 'native') -Filter '*.cs'|Sort-Object Name)){$trees.Add([Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText([IO.File]::ReadAllText($file.FullName),$parse,$file.Name,[Text.Encoding]::UTF8))}
$compilation=[Microsoft.CodeAnalysis.CSharp.CSharpCompilation]::Create('Domenia.Native',$trees.ToArray(),[Microsoft.CodeAnalysis.MetadataReference[]]$references,$options)
$stream=[IO.MemoryStream]::new()
try{
    $result=$compilation.Emit($stream)
    if(-not $result.Success -or @($result.Diagnostics|Where-Object{$_.Severity -in @('Error','Warning')}).Count){throw (($result.Diagnostics|ForEach-Object{$_.ToString()}) -join "`n")}
    $path=Join-Path $OutputDirectory 'Domenia.Native.dll';[IO.File]::WriteAllBytes($path,$stream.ToArray())
    Get-FileHash -LiteralPath $path -Algorithm SHA256|Select-Object Path,Hash|ConvertTo-Json
}finally{$stream.Dispose()}
