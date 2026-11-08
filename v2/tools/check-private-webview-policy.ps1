# Windows-only policy checks. The package gate separately inventories and launches the real copied runtime.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'private-webview-runtime.ps1')
function Require-Rejection([scriptblock]$Action, [string]$Label) {
    $rejected = $false
    try { & $Action } catch { $rejected = $true }
    if (-not $rejected) { throw "WebView2 policy: expected rejection: $Label" }
}
foreach ($version in @('', '155.0.4283.61', '154.9.9999.9999', '155.0.4283.62-beta', '155.0.4283', '9999999999.0.0.0')) {
    if (Test-PrivateWebViewVersion $version) { throw 'WebView2 policy: malformed/old version accepted.' }
}
foreach ($version in @('155.0.4283.62', '155.0.4283.63', '156.0.0.0')) {
    if (-not (Test-PrivateWebViewVersion $version)) { throw 'WebView2 policy: valid current version rejected.' }
}
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('domenia-webview-policy-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporary -ErrorAction Stop | Out-Null
$sample = Join-Path $temporary 'sample.bin'
try {
    # Existing Windows x64 PE, copied only into this isolated test directory. Its signer verdict below is scripted.
    [IO.File]::Copy((Join-Path $PSHOME 'powershell.exe'), $sample, $false)
    $expected = (Get-FileHash -LiteralPath $sample -Algorithm SHA256).Hash.ToLowerInvariant()
    # Mock only Windows' verdict to exercise our fail-closed policy. No certificate is installed.
    function Get-AuthenticodeSignature {
        param([string]$LiteralPath, [string]$ErrorAction)
        return $script:signatureFixture
    }
    $certificate = [pscustomobject]@{ Name = 'Microsoft Corporation' }
    $certificate | Add-Member -MemberType ScriptMethod -Name GetNameInfo -Value { param($kind, $issuer) return $this.Name }
    $script:signatureFixture = [pscustomobject]@{ Status = 'Valid'; SignerCertificate = $certificate }
    [void](Assert-PrivateWebViewMicrosoftSignature $sample $expected)
    Require-Rejection { Assert-PrivateWebViewMicrosoftSignature $sample ('0' * 64) } 'changed bytes'
    $certificate.Name = 'Other Publisher'
    Require-Rejection { Assert-PrivateWebViewMicrosoftSignature $sample $expected } 'other valid publisher'
    $certificate.Name = 'Microsoft Corporation'
    foreach ($status in @('NotSigned', 'HashMismatch', 'NotTrusted', 'UnknownError')) {
        $script:signatureFixture.Status = $status
        Require-Rejection { Assert-PrivateWebViewMicrosoftSignature $sample $expected } $status
    }
    $script:signatureFixture.Status = 'Valid'
    $script:signatureFixture.SignerCertificate = $null
    Require-Rejection { Assert-PrivateWebViewMicrosoftSignature $sample $expected } 'missing signer'
    Require-Rejection { Get-PrivateWebViewRuntime -SourceRoot $temporary } 'non-system source'
} finally {
    Remove-Item -LiteralPath $sample -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temporary -ErrorAction SilentlyContinue
}
Write-Output 'WebView2 private runtime policy: passed (scripted verdicts; real runtime checked by package gate).'
