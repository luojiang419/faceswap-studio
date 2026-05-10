using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

internal static class FaceSwapStudioLauncher
{
    [STAThread]
    private static int Main()
    {
        try
        {
            string repoRoot = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            string launchScript = Path.Combine(repoRoot, "launch_faceswap_studio.py");
            string embeddedPython = Path.GetFullPath(Path.Combine(repoRoot, "..", ".venv-win", "Scripts", "python.exe"));

            if (!File.Exists(launchScript))
            {
                ShowError("未找到启动脚本", "找不到 launch_faceswap_studio.py，请确认程序位于 facefusion 项目根目录。");
                return 1;
            }

            string pythonExe = File.Exists(embeddedPython) ? embeddedPython : "python";
            var startInfo = new ProcessStartInfo
            {
                FileName = pythonExe,
                Arguments = Quote(launchScript),
                WorkingDirectory = repoRoot,
                UseShellExecute = false,
                CreateNoWindow = true,
            };

            using (Process process = Process.Start(startInfo))
            {
                if (process == null)
                {
                    ShowError("启动失败", "无法创建启动进程。");
                    return 1;
                }

                process.WaitForExit();
                if (process.ExitCode != 0)
                {
                    ShowError("FaceSwap Studio 启动失败", "启动脚本已退出，退出码: " + process.ExitCode);
                }
                return process.ExitCode;
            }
        }
        catch (Exception exception)
        {
            ShowError("启动器异常", exception.ToString());
            return 1;
        }
    }

    private static string Quote(string value)
    {
        return "\"" + value + "\"";
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
}
