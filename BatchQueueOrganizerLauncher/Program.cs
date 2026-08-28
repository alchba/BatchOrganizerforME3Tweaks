using System.Diagnostics;
using System.Reflection;
using System.Windows.Forms;

namespace ME3TweaksBatchQueueOrganizer;

internal static class Program
{
    private static Process? childProcess;
    private static string? runtimeDirectory;

    [STAThread]
    private static int Main()
    {
        string appDirectory = AppContext.BaseDirectory;
#if DISTRIBUTION_BUILD
        runtimeDirectory = Path.Combine(Path.GetTempPath(), $"ME3TweaksBatchQueueOrganizer-{Environment.ProcessId}");
        Directory.CreateDirectory(runtimeDirectory);
        string scriptPath = Path.Combine(runtimeDirectory, "BatchQueueOrganizer.ps1");
        string iconPath = Path.Combine(runtimeDirectory, "ME3TweaksBatchQueueOrganizer.ico");
        ExtractResource("BatchQueueOrganizer.ps1", scriptPath);
        ExtractResource("ME3TweaksBatchQueueOrganizer.ico", iconPath);
#else
        string scriptPath = Path.Combine(appDirectory, "BatchQueueOrganizer.ps1");

        if (!File.Exists(scriptPath))
        {
            MessageBox.Show(
                $"BatchQueueOrganizer.ps1 was not found next to the application.\n\nExpected path:\n{scriptPath}",
                "ME3Tweaks Batch Queue Organizer",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return 2;
        }
#endif

        string powershellPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.System),
            "WindowsPowerShell",
            "v1.0",
            "powershell.exe");

        var startInfo = new ProcessStartInfo
        {
            FileName = powershellPath,
            Arguments = $"-NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -File \"{scriptPath}\" -StorageRoot \"{appDirectory.TrimEnd(Path.DirectorySeparatorChar)}\"",
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = appDirectory
        };

        try
        {
            childProcess = Process.Start(startInfo);
            if (childProcess is null)
            {
                throw new InvalidOperationException("Windows PowerShell could not be started.");
            }

            AppDomain.CurrentDomain.ProcessExit += (_, _) => StopChildProcess();
            Task<string> outputTask = childProcess.StandardOutput.ReadToEndAsync();
            Task<string> errorTask = childProcess.StandardError.ReadToEndAsync();
            childProcess.WaitForExit();
            Task.WaitAll(outputTask, errorTask);
            if (childProcess.ExitCode != 0)
            {
                string details = string.IsNullOrWhiteSpace(errorTask.Result) ? outputTask.Result : errorTask.Result;
                MessageBox.Show(
                    string.IsNullOrWhiteSpace(details) ? $"The organizer closed with error code {childProcess.ExitCode}." : details.Trim(),
                    "ME3Tweaks Batch Queue Organizer",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
            }
            return childProcess.ExitCode;
        }
        catch (Exception exception)
        {
            MessageBox.Show(
                exception.Message,
                "ME3Tweaks Batch Queue Organizer",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return 1;
        }
        finally
        {
            StopChildProcess();
            childProcess?.Dispose();
            childProcess = null;
            if (runtimeDirectory is not null)
            {
                try { Directory.Delete(runtimeDirectory, recursive: true); } catch { }
            }
        }
    }

    private static void ExtractResource(string resourceName, string destinationPath)
    {
        using Stream? source = Assembly.GetExecutingAssembly().GetManifestResourceStream(resourceName);
        if (source is null) { throw new InvalidOperationException($"Embedded resource was not found: {resourceName}"); }
        using FileStream destination = File.Create(destinationPath);
        source.CopyTo(destination);
    }

    private static void StopChildProcess()
    {
        try
        {
            if (childProcess is not null && !childProcess.HasExited)
            {
                childProcess.Kill(entireProcessTree: true);
                childProcess.WaitForExit(3000);
            }
        }
        catch
        {
            // The process may already be shutting down.
        }
    }
}
