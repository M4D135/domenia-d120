namespace Domenia.Core;

/// <summary>Closed metadata only. A secret, row payload or arbitrary object cannot enter this inspection contract.</summary>
public readonly record struct AccessResultStatus(bool Refused, bool AuthenticationRejected);
public readonly record struct AccessInspection(int Examined, bool Refused, bool AuthenticationRejected);

public static class AccessResultInspection
{
    public const int MaximumResults = 64;
    public static AccessInspection Inspect(IEnumerable<AccessResultStatus> results)
    {
        ArgumentNullException.ThrowIfNull(results);
        var count = 0; var refused = false; var rejected = false;
        using var iterator = results.GetEnumerator();
        // Do not even advance to item 65: providers may expose lazy/native sequences.
        while (count < MaximumResults && iterator.MoveNext())
        {
            var value = iterator.Current; count++;
            refused |= value.Refused; rejected |= value.AuthenticationRejected;
        }
        return new(count, refused || rejected, rejected);
    }
}
