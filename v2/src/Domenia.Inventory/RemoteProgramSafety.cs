using System.Text.RegularExpressions;

namespace Domenia.Inventory;

/// <summary>Defense in depth for the closed, hash-bound product programs. This is not a sanitizer for arbitrary scripts.
/// Nothing supplied by the operator may become executable text. Process-only launch flags are outside the script body.</summary>
internal static class RemoteProgramSafety
{
    private static readonly Regex Forbidden = new(
        @"\b(?:Set-ExecutionPolicy|Enable-PSRemoting|Enable-WSManCredSSP|Set-MpPreference|Add-MpPreference|Remove-MpPreference|Set-NetFirewallProfile|Disable-NetFirewallRule|Set-NetFirewallRule|New-NetFirewallRule|SkipCACheck|SkipCNCheck|SkipRevocationCheck|ServerCertificateValidationCallback|CertificateValidationCallback|TrustAllCertsPolicy|DisableRealtimeMonitoring|DisableBehaviorMonitoring|DisableAntiSpyware)\b"
        + @"|\bnetsh\s+(?:advfirewall|firewall)\b|\bwinrm\s+(?:quickconfig|set)\b"
        + @"|\b(?:Stop-Service|Set-Service|sc(?:\.exe)?\s+(?:stop|config))\s+[^\r\n]*(?:WinDefend|MpsSvc|WinRM)\b",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.NonBacktracking, TimeSpan.FromMilliseconds(100));

    internal static void RequireSafe(string script)
    {
        if (string.IsNullOrWhiteSpace(script) || script.Length > 256 * 1024 || script.Contains('\0') || Forbidden.IsMatch(script))
            throw new InvalidDataException("Programme distant refusé : modification de sécurité ou contenu hors contrat.");
    }
}
