using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Windows.Forms;

[assembly: System.Reflection.AssemblyTitle("易容 Studio")]
[assembly: System.Reflection.AssemblyProduct("易容 Studio")]

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
                    "易容 Studio",
                    "易容 Studio 异常退出（退出码 0x" + exitCode.ToString("X8") + "）。\n" +
                    "请查看 launcher.log、bridge.log 和以下日志：\n" + wrapperLogPath
                );
            }
            return exitCode;
        }
        catch (Exception exception)
        {
            AppendLog(wrapperLogPath, "[wrapper] Fatal error: " + exception);
            ShowError(
                "易容 Studio",
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

        startInfo.EnvironmentVariables["FACESWAP_STUDIO_WRAPPER_PID"] = Process.GetCurrentProcess().Id.ToString();
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
            // 同时排空两个管道，避免核心导入错误或大量输出撑满 stderr 后互相等待。
            var stdoutTask = process.StandardOutput.ReadToEndAsync();
            var stderrTask = process.StandardError.ReadToEndAsync();
            process.WaitForExit();
            string stdout = stdoutTask.Result;
            string stderr = stderrTask.Result;

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
        // 更新器拥有错误展示与回滚；模态弹窗会使 wrapper 一直存活、锁住更新文件。
        if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("FACESWAP_STUDIO_UPDATE_SESSION")))
        {
            return;
        }
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
