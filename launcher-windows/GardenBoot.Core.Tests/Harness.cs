using System.Reflection;
using System.Runtime.CompilerServices;

namespace GardenBoot.Core.Tests;

[AttributeUsage(AttributeTargets.Method)]
public sealed class TestAttribute : Attribute;

public sealed class CheckFailed(string message) : Exception(message);

/// <summary>Minimal assertions; every failure names the call site.</summary>
public static class Check
{
    public static void True(bool condition, string what = "", [CallerFilePath] string file = "", [CallerLineNumber] int line = 0)
    {
        if (!condition) throw new CheckFailed($"{Path.GetFileName(file)}:{line} expected true {what}");
    }

    public static void False(bool condition, string what = "", [CallerFilePath] string file = "", [CallerLineNumber] int line = 0)
    {
        if (condition) throw new CheckFailed($"{Path.GetFileName(file)}:{line} expected false {what}");
    }

    public static void Equal<T>(T expected, T actual, string what = "", [CallerFilePath] string file = "", [CallerLineNumber] int line = 0)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
            throw new CheckFailed($"{Path.GetFileName(file)}:{line} {what}\n      expected: {expected}\n      actual:   {actual}");
    }

    public static void Near(double expected, double actual, double tolerance = 1e-9, string what = "",
                            [CallerFilePath] string file = "", [CallerLineNumber] int line = 0)
    {
        if (!(Math.Abs(expected - actual) <= tolerance))
            throw new CheckFailed($"{Path.GetFileName(file)}:{line} {what} expected {expected} got {actual}");
    }

    public static void Sequence(IEnumerable<string> expected, IEnumerable<string> actual, string what = "",
                                [CallerFilePath] string file = "", [CallerLineNumber] int line = 0)
    {
        var e = expected.ToList();
        var a = actual.ToList();
        if (!e.SequenceEqual(a))
            throw new CheckFailed($"{Path.GetFileName(file)}:{line} {what}\n      expected: [{string.Join(", ", e)}]\n      actual:   [{string.Join(", ", a)}]");
    }

    public static TException Throws<TException>(Action action, string what = "", [CallerFilePath] string file = "", [CallerLineNumber] int line = 0)
        where TException : Exception
    {
        try { action(); }
        catch (TException e) { return e; }
        catch (Exception e) { throw new CheckFailed($"{Path.GetFileName(file)}:{line} {what} threw {e.GetType().Name}: {e.Message}"); }
        throw new CheckFailed($"{Path.GetFileName(file)}:{line} {what} did not throw {typeof(TException).Name}");
    }

    public static async Task<TException> ThrowsAsync<TException>(Func<Task> action, string what = "",
                                                                 [CallerFilePath] string file = "", [CallerLineNumber] int line = 0)
        where TException : Exception
    {
        try { await action(); }
        catch (TException e) { return e; }
        catch (Exception e) { throw new CheckFailed($"{Path.GetFileName(file)}:{line} {what} threw {e.GetType().Name}: {e.Message}"); }
        throw new CheckFailed($"{Path.GetFileName(file)}:{line} {what} did not throw {typeof(TException).Name}");
    }
}

public static class Program
{
    public static async Task<int> Main(string[] args)
    {
        if (args.FirstOrDefault() == "--prepare-update") return await UpdateHarness.Prepare(args);
        var filter = args.FirstOrDefault();
        var tests = typeof(Program).Assembly.GetTypes()
            .SelectMany(t => t.GetMethods(BindingFlags.Public | BindingFlags.Static))
            .Where(m => m.GetCustomAttribute<TestAttribute>() is not null)
            .Where(m => filter is null || $"{m.DeclaringType!.Name}.{m.Name}".Contains(filter, StringComparison.OrdinalIgnoreCase))
            .OrderBy(m => m.DeclaringType!.Name).ThenBy(m => m.Name)
            .ToList();
        int failed = 0;
        foreach (var test in tests)
        {
            var name = $"{test.DeclaringType!.Name}.{test.Name}";
            try
            {
                if (test.Invoke(null, null) is Task task) await task;
                Console.WriteLine($"PASS {name}");
            }
            catch (Exception e)
            {
                failed++;
                var inner = e is TargetInvocationException { InnerException: { } i } ? i : e;
                Console.WriteLine($"FAIL {name}\n    {inner.Message}");
            }
        }
        Console.WriteLine($"{tests.Count - failed}/{tests.Count} passed");
        return failed == 0 && tests.Count > 0 ? 0 : 1;
    }
}
