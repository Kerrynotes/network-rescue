using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Security.AccessControl;
using System.Security.Principal;
using System.ServiceProcess;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace KerryNetworkRescue.Helper
{
    internal static class Program
    {
        internal const string ServiceNameValue = "KerryNetworkRescueHelper";
        internal const string PipeName = "KerryNetworkRescue.Helper.v1";
        internal static SecurityIdentifier AuthorizedSid;

        private static int Main(string[] args)
        {
            try
            {
                if (args.Any(a => string.Equals(a, "--selftest", StringComparison.OrdinalIgnoreCase)))
                {
                    Console.WriteLine(Policy.RunSelfTest() + " " + HelperService.RunLogRotationSelfTest());
                    return 0;
                }

                var sidIndex = Array.FindIndex(args, a => string.Equals(a, "--sid", StringComparison.OrdinalIgnoreCase));
                if (sidIndex < 0 || sidIndex + 1 >= args.Length)
                {
                    Console.Error.WriteLine("缺少 --sid 参数。");
                    return 2;
                }
                AuthorizedSid = new SecurityIdentifier(args[sidIndex + 1]);

                if (args.Any(a => string.Equals(a, "--console", StringComparison.OrdinalIgnoreCase)))
                {
                    using (var service = new HelperService())
                    {
                        service.StartConsole();
                        Console.WriteLine("断网急救 Helper 控制台模式已启动，按 Enter 退出。");
                        Console.ReadLine();
                        service.StopConsole();
                    }
                    return 0;
                }

                ServiceBase.Run(new HelperService());
                return 0;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine(ex.ToString());
                return 1;
            }
        }
    }

    internal static class Policy
    {
        private static readonly HashSet<string> AllowedModes = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "StopServices", "StartServices", "KillProcesses", "CleanupTun", "ResetDns", "RestoreMachineDirect"
        };

        private static HashSet<string> GetAllowedClients()
        {
            var result = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var adapterPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "client_adapters.json");
            if (!File.Exists(adapterPath)) return result;
            var json = File.ReadAllText(adapterPath, Encoding.UTF8);
            foreach (Match match in Regex.Matches(json, "\\\"id\\\"\\s*:\\s*\\\"(?<id>[a-z0-9_]+)\\\"", RegexOptions.IgnoreCase))
                result.Add(match.Groups["id"].Value);
            return result;
        }

        internal static bool TryValidateRun(string mode, string clientIds, out string normalizedIds, out string error)
        {
            normalizedIds = string.Empty;
            error = string.Empty;
            if (!AllowedModes.Contains(mode))
            {
                error = "不允许的 Helper 操作。";
                return false;
            }

            var ids = (clientIds ?? string.Empty)
                .Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries)
                .Select(id => id.Trim())
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToArray();
            var allowedClients = GetAllowedClients();
            if (allowedClients.Count == 0)
            {
                error = "受保护的客户端适配器白名单为空。";
                return false;
            }
            if (ids.Any(id => !allowedClients.Contains(id)))
            {
                error = "包含未授权的客户端 ID。";
                return false;
            }
            normalizedIds = string.Join(",", ids);
            return true;
        }

        internal static string RunSelfTest()
        {
            string ids;
            string error;
            if (!TryValidateRun("StopServices", "clash_verge,longmao", out ids, out error))
                throw new InvalidOperationException("合法操作被拒绝。");
            if (TryValidateRun("RunCommand", "clash_verge", out ids, out error))
                throw new InvalidOperationException("任意命令未被拒绝。");
            if (TryValidateRun("StopServices", "clash_verge;whoami", out ids, out error))
                throw new InvalidOperationException("非法客户端 ID 未被拒绝。");
            return "Helper 自检通过：操作和客户端白名单正常。";
        }
    }

    internal sealed class HelperService : ServiceBase
    {
        private const long LogMaxBytes = 2L * 1024L * 1024L;
        private const int LogArchiveCount = 3;
        private readonly ManualResetEvent stopEvent = new ManualResetEvent(false);
        private Thread worker;

        internal HelperService()
        {
            ServiceName = Program.ServiceNameValue;
            CanStop = true;
            AutoLog = true;
        }

        protected override void OnStart(string[] args) { StartWorker(); }
        protected override void OnStop() { StopWorker(); }
        internal void StartConsole() { StartWorker(); }
        internal void StopConsole() { StopWorker(); }

        private void StartWorker()
        {
            stopEvent.Reset();
            worker = new Thread(ServerLoop) { IsBackground = true, Name = "NetworkRescueHelperPipe" };
            worker.Start();
            Log("Helper 已启动。", "INFO");
        }

        private void StopWorker()
        {
            stopEvent.Set();
            try
            {
                using (var wake = new NamedPipeClientStream(".", Program.PipeName, PipeDirection.InOut))
                    wake.Connect(500);
            }
            catch { }
            if (worker != null && worker.IsAlive) worker.Join(3000);
            Log("Helper 已停止。", "INFO");
        }

        private void ServerLoop()
        {
            while (!stopEvent.WaitOne(0))
            {
                try
                {
                    using (var pipe = CreatePipe())
                    {
                        pipe.WaitForConnection();
                        if (stopEvent.WaitOne(0)) return;
                        HandleClient(pipe);
                    }
                }
                catch (Exception ex)
                {
                    Log("IPC 异常：" + ex.Message, "ERROR");
                    Thread.Sleep(500);
                }
            }
        }

        private static NamedPipeServerStream CreatePipe()
        {
            var security = new PipeSecurity();
            security.SetAccessRuleProtection(true, false);
            security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), PipeAccessRights.FullControl, AccessControlType.Allow));
            security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null), PipeAccessRights.FullControl, AccessControlType.Allow));
            security.AddAccessRule(new PipeAccessRule(Program.AuthorizedSid, PipeAccessRights.ReadWrite, AccessControlType.Allow));
            return new NamedPipeServerStream(Program.PipeName, PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
                PipeOptions.WriteThrough, 4096, 4096, security);
        }

        private static void HandleClient(NamedPipeServerStream pipe)
        {
            pipe.ReadMode = PipeTransmissionMode.Byte;
            using (var reader = new StreamReader(pipe, new UTF8Encoding(false), false, 4096, true))
            using (var writer = new StreamWriter(pipe, new UTF8Encoding(false), 4096, true) { AutoFlush = true })
            {
                var request = reader.ReadLine();
                if (string.Equals(request, "PING", StringComparison.Ordinal))
                {
                    writer.WriteLine("OK|PONG");
                    return;
                }
                var parts = (request ?? string.Empty).Split('|');
                if (parts.Length != 3 || !string.Equals(parts[0], "RUN", StringComparison.Ordinal))
                {
                    writer.WriteLine("ERROR|" + Encode("请求格式无效。"));
                    return;
                }

                string normalizedIds;
                string validationError;
                if (!Policy.TryValidateRun(parts[1], parts[2], out normalizedIds, out validationError))
                {
                    writer.WriteLine("ERROR|" + Encode(validationError));
                    return;
                }

                var result = RunPrivilegedScript(parts[1], normalizedIds);
                writer.WriteLine("RESULT|" + result.Item1 + "|" + Encode(result.Item2));
            }
        }

        private static Tuple<int, string> RunPrivilegedScript(string mode, string clientIds)
        {
            var baseDirectory = AppDomain.CurrentDomain.BaseDirectory;
            var scriptPath = Path.Combine(baseDirectory, "Privileged-Repair.ps1");
            if (!File.Exists(scriptPath)) return Tuple.Create(3, "未找到受保护的修复脚本。");

            var arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + scriptPath + "\" -Mode " + mode;
            if (!string.IsNullOrWhiteSpace(clientIds)) arguments += " -ClientIds \"" + clientIds + "\"";
            var startInfo = new ProcessStartInfo
            {
                FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell\\v1.0\\powershell.exe"),
                Arguments = arguments,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                WorkingDirectory = baseDirectory
            };
            using (var process = Process.Start(startInfo))
            {
                var standardOutput = new StringBuilder();
                var standardError = new StringBuilder();
                process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs eventArgs)
                {
                    if (eventArgs.Data != null) lock (standardOutput) standardOutput.AppendLine(eventArgs.Data);
                };
                process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs eventArgs)
                {
                    if (eventArgs.Data != null) lock (standardError) standardError.AppendLine(eventArgs.Data);
                };
                process.BeginOutputReadLine();
                process.BeginErrorReadLine();
                if (!process.WaitForExit(120000))
                {
                    try { process.Kill(); } catch { }
                    try { process.WaitForExit(5000); } catch { }
                    Log("高权限操作超时：" + mode, "ERROR");
                    return Tuple.Create(4, "高权限操作超过 120 秒，已终止。\n" + standardOutput.ToString() + standardError.ToString());
                }
                process.WaitForExit();
                var output = standardOutput.ToString() + standardError.ToString();
                Log("高权限操作完成：" + mode + "，退出码=" + process.ExitCode, process.ExitCode == 0 ? "INFO" : "ERROR");
                return Tuple.Create(process.ExitCode, output.Trim());
            }
        }

        private static string Encode(string value)
        {
            return Convert.ToBase64String(Encoding.UTF8.GetBytes(value ?? string.Empty));
        }

        private static void Log(string message, string level)
        {
            try
            {
                var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "KerryNetworkRescue");
                Directory.CreateDirectory(root);
                var path = Path.Combine(root, "helper.log");
                var line = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " [" + level + "] " + message + Environment.NewLine;
                RotateLogIfNeeded(path, LogMaxBytes, LogArchiveCount, Encoding.UTF8.GetByteCount(line));
                File.AppendAllText(path, line, new UTF8Encoding(true));
            }
            catch { }
        }

        private static void RotateLogIfNeeded(string path, long maxBytes, int archiveCount, long incomingBytes)
        {
            if (maxBytes <= 0 || archiveCount < 1 || !File.Exists(path)) return;
            if (new FileInfo(path).Length + incomingBytes <= maxBytes) return;

            var oldest = path + "." + archiveCount;
            if (File.Exists(oldest)) File.Delete(oldest);
            for (var index = archiveCount - 1; index >= 1; index--)
            {
                var source = path + "." + index;
                if (File.Exists(source)) File.Move(source, path + "." + (index + 1));
            }
            File.Move(path, path + ".1");
        }

        internal static string RunLogRotationSelfTest()
        {
            var path = Path.Combine(Path.GetTempPath(), "network-rescue-helper-rotation-" + Process.GetCurrentProcess().Id + ".log");
            try
            {
                File.WriteAllBytes(path, new byte[96]);
                RotateLogIfNeeded(path, 100, 3, 10);
                if (File.Exists(path) || !File.Exists(path + ".1")) throw new InvalidOperationException("Helper 日志轮转测试失败。");
                return "Helper 日志轮转自检通过。";
            }
            finally
            {
                if (File.Exists(path)) File.Delete(path);
                for (var index = 1; index <= 3; index++)
                {
                    var archive = path + "." + index;
                    if (File.Exists(archive)) File.Delete(archive);
                }
            }
        }
    }
}
