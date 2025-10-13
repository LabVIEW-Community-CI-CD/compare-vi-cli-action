namespace CompareVi.Tools.Cli;

internal static class Program
{
    private static int Main(string[] args)
    {
        if (args.Length == 0)
        {
            PrintUsage();
            return 1;
        }

        var command = args[0].ToLowerInvariant();
        var remaining = args.Skip(1).ToArray();

        return command switch
        {
            "compare" => CompareCommands.Dispatch(remaining),
            "trace" => TraceCommands.Dispatch(remaining),
            "nunit" => CompareCommands.DispatchNunit(remaining),
            _ => UnknownCommand(command)
        };
    }

    private static int UnknownCommand(string command)
    {
        Console.Error.WriteLine($"Unknown command '{command}'.");
        PrintUsage();
        return 2;
    }

    private static void PrintUsage()
    {
        Console.WriteLine("CompareVi.Tools.Cli");
        Console.WriteLine("Commands:");
        Console.WriteLine("  compare parse --search <dir> --out <path>");
        Console.WriteLine("  compare nunit --base <path> --head <path> [options]");
        Console.WriteLine("  trace build --tests <dir> --results <dir> [options]");
    }
}
