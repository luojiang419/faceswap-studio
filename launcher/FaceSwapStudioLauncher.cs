using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Windows.Forms;

internal static class FaceSwapStudioLauncher
{
    [STAThread]
    private static int Main()
    {
        string repoRoot = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(
            Path.DirectorySeparatorChar,
            Path.AltDirectorySeparatorChar
        );
        string runtimeDir = Path.Combine(repoRoot, "faceswap studio", "runtime");
        string wrapperLogPath = Path.Combine(runtimeDir, "launcher-wrapper.log");

        try
        {
            Directory.CreateDirectory(runtimeDir);

            string scriptPath = Path.Combine(repoRoot, "launch_faceswap_studio.py");
            if (!File.Exists(scriptPath))
            {
                throw new FileNotFoundException("Launcher script was not found.", scriptPath);
            }

            string pythonExe = ResolvePythonExecutable(repoRoot);
            int exitCode = RunPythonLauncher(pythonExe, scriptPath, repoRoot, wrapperLogPath);
            if (exitCode != 0)
            {
                ShowError(
                    "FaceSwap Studio",
                    "Launcher exited with an error. See:\n" + wrapperLogPath
                );
            }
            return exitCode;
        }
        catch (Exception exception)
        {
            AppendLog(wrapperLogPath, "[wrapper] Fatal error: " + exception);
            ShowError(
                "FaceSwap Studio",
                "Launcher failed to start.\n\n" + exception.Message + "\n\nSee:\n" + wrapperLogPath
            );
            return 1;
        }
    }

    private static string ResolvePythonExecutable(string repoRoot)
    {
        string[] candidates =
        {
            Path.Combine(repoRoot, ".venv-win", "Scripts", "python.exe"),
            Path.Combine(repoRoot, ".bootstrap", "nuget", "python", "tools", "python.exe")
        };

        foreach (string candidate in candidates)
        {
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        throw new FileNotFoundException(
            "No usable Python runtime was found. Run scripts/install_facefusion.ps1 first."
        );
    }

    private static int RunPythonLauncher(string pythonExe, string scriptPath, string repoRoot, string wrapperLogPath)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = pythonExe,
            Arguments = Quote(scriptPath),
            WorkingDirectory = repoRoot,
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };

        startInfo.EnvironmentVariables["FACEFUSION_HUGGINGFACE_MIRRORS"] = "https://hf-mirror.com";
        startInfo.EnvironmentVariables["FACEFUSION_GITHUB_MIRRORS"] = "https://github.com";
        startInfo.EnvironmentVariables["FACEFUSION_DISABLE_PROXY"] = "1";
        startInfo.EnvironmentVariables["NO_PROXY"] = "*";
        startInfo.EnvironmentVariables["no_proxy"] = "*";

        foreach (string proxyKey in new[]
        {
            "HTTP_PROXY",
            "HTTPS_PROXY",
            "ALL_PROXY",
            "http_proxy",
            "https_proxy",
            "all_proxy"
        })
        {
            startInfo.EnvironmentVariables.Remove(proxyKey);
        }

        using (var process = new Process { StartInfo = startInfo })
        {
            process.Start();
            string stdout = process.StandardOutput.ReadToEnd();
            string stderr = process.StandardError.ReadToEnd();
            process.WaitForExit();

            if (!string.IsNullOrWhiteSpace(stdout))
            {
                AppendLog(wrapperLogPath, "[wrapper] stdout:\n" + stdout.TrimEnd());
            }
            if (!string.IsNullOrWhiteSpace(stderr))
            {
                AppendLog(wrapperLogPath, "[wrapper] stderr:\n" + stderr.TrimEnd());
            }
            AppendLog(wrapperLogPath, "[wrapper] ExitCode=" + process.ExitCode);

            return process.ExitCode;
        }
    }

    private static void AppendLog(string logPath, string message)
    {
        string timestamp = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
        using (var writer = new StreamWriter(logPath, true, Encoding.UTF8))
        {
            writer.WriteLine("[" + timestamp + "] " + message);
        }
    }

    private static void ShowError(string title, string message)
    {
        MessageBox.Show(
            message,
            title,
            MessageBoxButtons.OK,
            MessageBoxIcon.Error
        );
    }

    private static string Quote(string value)
    {
        return "\"" + value + "\"";
    }
}
