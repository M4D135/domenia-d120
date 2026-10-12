#requires -Version 5.1
# Build only: reuse an explicitly provided net472 reference pack; never download at runtime.
param([Parameter(Mandatory=$true)][string]$ReferenceDirectory,[string]$OutputDirectory='',[string]$CompilerDirectory='')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
if(-not $OutputDirectory){$OutputDirectory=Join-Path $root 'wad/modules'}
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
