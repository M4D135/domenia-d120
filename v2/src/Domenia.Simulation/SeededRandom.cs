using System.Text;

namespace Domenia.Simulation;

/// <summary>
/// SplitMix64 generator whose sequence is fixed by this code and independent of any .NET version (System.Random is not used).
/// Named sub-streams derive from the root seed and the FNV-1a 64 hash of their name, so adding draws to one stream never
/// shifts another.
/// </summary>
public sealed class SeededRandom
{
    private const ulong Golden = 0x9E3779B97F4A7C15;
    private const ulong FnvOffset = 14695981039346656037;
    private const ulong FnvPrime = 1099511628211;

    private readonly ulong seed;
    private ulong state;

    public SeededRandom(ulong seed)
    {
        this.seed = seed;
        state = seed;
    }

    public ulong Seed => seed;

    /// <summary>Independent sub-stream: depends only on the root seed and the name, never on draws already made.</summary>
    public SeededRandom Fork(string name)
    {
        ArgumentNullException.ThrowIfNull(name);
        return new SeededRandom(Mix(unchecked((seed ^ Fnv1a64(name)) + Golden)));
    }

    public ulong NextUInt64()
    {
        unchecked
        {
            state += Golden;
            return Mix(state);
        }
    }

    public uint NextUInt32() => (uint)(NextUInt64() >> 32);

    /// <summary>Unbiased integer in [0 ; <paramref name="maxExclusive"/>[ by rejection.</summary>
    public int Next(int maxExclusive)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(maxExclusive, 1);
        return (int)NextUInt64Below((ulong)maxExclusive);
    }

    /// <summary>Unbiased integer in [<paramref name="minInclusive"/> ; <paramref name="maxExclusive"/>[.</summary>
    public int Next(int minInclusive, int maxExclusive)
    {
        ArgumentOutOfRangeException.ThrowIfGreaterThanOrEqual(minInclusive, maxExclusive);
        return (int)(minInclusive + (long)NextUInt64Below((ulong)((long)maxExclusive - minInclusive)));
    }

    /// <summary>Unbiased 64-bit integer in [<paramref name="minInclusive"/> ; <paramref name="maxExclusive"/>[.</summary>
    public long NextInt64(long minInclusive, long maxExclusive)
    {
        ArgumentOutOfRangeException.ThrowIfGreaterThanOrEqual(minInclusive, maxExclusive);
        return unchecked(minInclusive + (long)NextUInt64Below((ulong)(maxExclusive - minInclusive)));
    }

    /// <summary>Uniform double in [0 ; 1[ with 53 random bits.</summary>
    public double NextDouble() => (NextUInt64() >> 11) * (1.0 / (1UL << 53));

    /// <summary>True with probability <paramref name="percent"/> %.</summary>
    public bool Chance(int percent) => Next(100) < percent;

    /// <summary>Random duration in [<paramref name="min"/> ; <paramref name="max"/>], to the second.</summary>
    public TimeSpan Between(TimeSpan min, TimeSpan max)
    {
        var low = (long)min.TotalSeconds;
        var high = (long)max.TotalSeconds;
        return high <= low ? TimeSpan.FromSeconds(low) : TimeSpan.FromSeconds(NextInt64(low, high + 1));
    }

    public T Pick<T>(IReadOnlyList<T> items)
    {
        ArgumentNullException.ThrowIfNull(items);
        return items[Next(items.Count)];
    }

    /// <summary>Fisher-Yates shuffle, in place.</summary>
    public void Shuffle<T>(IList<T> items)
    {
        ArgumentNullException.ThrowIfNull(items);
        for (var i = items.Count - 1; i > 0; i--)
        {
            var j = Next(i + 1);
            (items[i], items[j]) = (items[j], items[i]);
        }
    }

    public static ulong Fnv1a64(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        var hash = FnvOffset;
        foreach (var b in Encoding.UTF8.GetBytes(text))
        {
            hash = unchecked((hash ^ b) * FnvPrime);
        }
        return hash;
    }

    private ulong NextUInt64Below(ulong bound)
    {
        // Rejection of the top incomplete range keeps every value equally likely.
        var limit = ulong.MaxValue - (ulong.MaxValue % bound + 1) % bound;
        while (true)
        {
            var value = NextUInt64();
            if (value <= limit)
            {
                return value % bound;
            }
        }
    }

    private static ulong Mix(ulong z)
    {
        unchecked
        {
            z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9;
            z = (z ^ (z >> 27)) * 0x94D049BB133111EB;
            return z ^ (z >> 31);
        }
    }
}
