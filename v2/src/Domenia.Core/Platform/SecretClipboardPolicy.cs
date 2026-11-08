namespace Domenia.Core;

public static class SecretClipboardPolicy
{
    public const int MaximumCharacters = 8192;
    public const int BitLockerMaximumCharacters = 1024;
    public static bool Allows(ReadOnlySpan<char> value, bool bitLocker = false) => value.Length > 0
        && value.Length <= (bitLocker ? BitLockerMaximumCharacters : MaximumCharacters) && value.IndexOf('\0') < 0;
    public static void Require(ReadOnlySpan<char> value, bool bitLocker = false)
    {
        if (!Allows(value, bitLocker)) throw new ArgumentException("Valeur secrète vide ou hors des limites de copie ; aucune copie effectuée.");
    }
}
