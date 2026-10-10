using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Diagnostics;

class MockOpenCode
{
    static int Main(string[] args)
    {
        string mode = "success";
        int sleepMs = 0;
        int exitCode = 0;
        int tokensIn = 100;
        int tokensOut = 200;
        int tokensReasoning = 25;
        int cacheRead = 50;
        int cacheWrite = 10;
        double cost = 0.005;
        string sessionId = "ses_mock_123";
        string controlPath = Path.Combine(Directory.GetCurrentDirectory(), "opencode-mock-control.txt");
        string grandchildExe = null;
        string grandchildArgs = null;
        string stopFile = null;

        foreach (var arg in args)
        {
            if (arg.StartsWith("--mock-mode=")) mode = arg.Substring(12);
            else if (arg.StartsWith("--mock-sleep=")) int.TryParse(arg.Substring(13), out sleepMs);
            else if (arg.StartsWith("--mock-exit-code=")) int.TryParse(arg.Substring(17), out exitCode);
            else if (arg.StartsWith("--mock-tokens-in=")) int.TryParse(arg.Substring(17), out tokensIn);
            else if (arg.StartsWith("--mock-tokens-out=")) int.TryParse(arg.Substring(18), out tokensOut);
            else if (arg.StartsWith("--mock-tokens-reasoning=")) int.TryParse(arg.Substring(24), out tokensReasoning);
            else if (arg.StartsWith("--mock-cost=")) double.TryParse(arg.Substring(12), System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out cost);
            else if (arg.StartsWith("--mock-session-id=")) sessionId = arg.Substring(18);
            else if (arg.StartsWith("--mock-control-file=")) controlPath = arg.Substring(20);
            else if (arg.StartsWith("--mock-grandchild-exe=")) grandchildExe = arg.Substring(22);
            else if (arg.StartsWith("--mock-grandchild-args=")) grandchildArgs = arg.Substring(23);
            else if (arg.StartsWith("--mock-stop-file=")) stopFile = arg.Substring(17);
        }

        if (File.Exists(controlPath))
        {
            foreach (string line in File.ReadAllLines(controlPath))
            {
                if (line.StartsWith("mode=")) mode = line.Substring(5).Trim();
                else if (line.StartsWith("sleep=")) int.TryParse(line.Substring(6).Trim(), out sleepMs);
                else if (line.StartsWith("exit_code=")) int.TryParse(line.Substring(10).Trim(), out exitCode);
                else if (line.StartsWith("tokens_in=")) int.TryParse(line.Substring(10).Trim(), out tokensIn);
                else if (line.StartsWith("tokens_out=")) int.TryParse(line.Substring(11).Trim(), out tokensOut);
            }
        }

        if (sleepMs > 0) Thread.Sleep(sleepMs);

        // Spawn a background grandchild process if requested to test Job tree containment
        if (!string.IsNullOrEmpty(grandchildExe) && File.Exists(grandchildExe))
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = grandchildExe;
                psi.Arguments = grandchildArgs ?? "";
                psi.UseShellExecute = false;
                Process grandchild = Process.Start(psi);
                if (grandchild != null)
                {
                    File.WriteAllText(Path.Combine(Directory.GetCurrentDirectory(), "opencode-grandchild.pid"), grandchild.Id.ToString());
                }
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("Failed to launch grandchild: " + ex.Message);
            }
        }

        if (mode == "stdin")
        {
            using (Stream stdin = Console.OpenStandardInput())
            {
                byte[] buffer = new byte[256];
                while (stdin.Read(buffer, 0, buffer.Length) > 0) { }
            }
            WriteSuccess(sessionId, tokensIn, tokensOut, tokensReasoning, cacheRead, cacheWrite, cost);
            return exitCode;
        }

        if (mode == "env")
        {
            File.WriteAllText(
                Path.Combine(Directory.GetCurrentDirectory(), "opencode-child-evidence.json"),
                EnvEvidence());
            WriteSuccess(sessionId, tokensIn, tokensOut, tokensReasoning, cacheRead, cacheWrite, cost);
            return exitCode;
        }

        if (mode == "argv")
        {
            File.WriteAllText(
                Path.Combine(Directory.GetCurrentDirectory(), "opencode-argv.json"),
                EncodeArgs(args));
            WriteSuccess(sessionId, tokensIn, tokensOut, tokensReasoning, cacheRead, cacheWrite, cost);
            return exitCode;
        }

        if (mode == "partial")
        {
            WriteStepStart(sessionId, "msg_01");
            return exitCode;
        }

        if (mode == "malformed")
        {
            Console.WriteLine("not-json-at-all-malformed-line");
            Console.Out.Flush();
            WriteSuccess(sessionId, tokensIn, tokensOut, tokensReasoning, cacheRead, cacheWrite, cost);
            return exitCode;
        }

        if (mode == "malformed-secret")
        {
            // Raw secret bytes. This mode does not redact.
            Console.WriteLine("{\"type\":\"tool_use\",\"broken\":\"sk-ant-api03-abcdefghijklmnopqrstuvwxyz LINEAR_API_KEY=lin_api_abcdefghijklmnopqrstuvwxyz");
            Console.Out.Flush();
            WriteSuccess(sessionId, tokensIn, tokensOut, tokensReasoning, cacheRead, cacheWrite, cost);
            return exitCode;
        }

        if (mode == "tool-calls-only")
        {
            WriteStepStart(sessionId, "msg_01");
            WriteStepFinish(sessionId, "tool-calls", "msg_01", 40, 60, 10, 5, 5, 0.002);
            return exitCode;
        }

        if (mode == "multi-step")
        {
            WriteStepStart(sessionId, "msg_01");
            WriteStepFinish(sessionId, "tool-calls", "msg_01", 40, 60, 10, 5, 5, 0.002);
            WriteToolUse(sessionId, "toolu_01", "msg_01", "read", "call_99", "completed", "file contents");
            WriteStepStart(sessionId, "msg_02");
            WriteStepFinish(sessionId, "stop", "msg_02", 60, 90, 15, 10, 5, 0.003);
            return exitCode;
        }

        if (mode == "tool-failure" || mode == "tool-error")
        {
            WriteStepStart(sessionId, "msg_err");
            WriteToolUse(sessionId, "toolu_err", "msg_err", "read", "call_err", "error", "permission denied");
            WriteStepFinish(sessionId, "stop", "msg_err", 100, 200, 25, 50, 10, 0.005);
            return (exitCode != 0) ? exitCode : 0;
        }

        if (mode == "secret")
        {
            // Valid JSON and stderr both keep the raw secret. Redaction is not done here.
            WriteToolUse(sessionId, "toolu_secret", "msg_secret", "read", "call_secret", "completed", "sk-ant-api03-abcdefghijklmnopqrstuvwxyz LINEAR_API_KEY=lin_api_abcdefghijklmnopqrstuvwxyz");
            WriteStepFinish(sessionId, "stop", "msg_secret", 10, 20, 0, 0, 0, 0.0);
            Console.Out.Flush();
            Console.Error.WriteLine("stderr sk-ant-api03-abcdefghijklmnopqrstuvwxyz LINEAR_API_KEY=lin_api_abcdefghijklmnopqrstuvwxyz");
            Console.Error.Flush();
            return exitCode;
        }

        if (mode == "stalled" || mode == "hang")
        {
            WriteStepStart(sessionId, "msg_01");
            Console.Out.Flush();
            while (true)
            {
                if (!string.IsNullOrEmpty(stopFile) && File.Exists(stopFile))
                {
                    break;
                }
                Thread.Sleep(500);
            }
            return exitCode;
        }

        if (mode == "interrupted")
        {
            WriteStepStart(sessionId, "msg_01");
            Console.WriteLine("{\"type\":\"text\",\"timestamp\":1700000000050,\"sessionID\":\"" + sessionId + "\",\"part\":{\"type\":\"text\",\"text\":\"partial text before sudden interruption\"}}");
            Console.Out.Flush();
            return (exitCode != 0) ? exitCode : 130;
        }

        if (mode == "error")
        {
            // Observed process failure only. This does not apply a no-fallback policy.
            Console.WriteLine("{\"type\":\"error\",\"timestamp\":1700000000000,\"sessionID\":\"" + sessionId + "\",\"error\":{\"name\":\"ModelNotFoundError\",\"data\":{\"message\":\"Model not found: test/not-found\"} }}");
            Console.Out.Flush();
            return (exitCode != 0) ? exitCode : 1;
        }

        if (mode == "success" || mode == "single-turn")
        {
            WriteSuccess(sessionId, tokensIn, tokensOut, tokensReasoning, cacheRead, cacheWrite, cost);
            return exitCode;
        }

        WriteSuccess(sessionId, tokensIn, tokensOut, tokensReasoning, cacheRead, cacheWrite, cost);
        return exitCode;
    }

    static void WriteSuccess(string sessionId, int input, int output, int reasoning, int cacheRead, int cacheWrite, double cost)
    {
        WriteStepStart(sessionId, "msg_01");
        WriteToolUse(sessionId, "toolu_01", "msg_01", "read", "call_99", "completed", "file contents");
        WriteStepFinish(sessionId, "stop", "msg_01", input, output, reasoning, cacheRead, cacheWrite, cost);
        Console.Out.Flush();
        Thread.Sleep(50);
        Console.Error.WriteLine("not-json-stderr-marker");
        Console.Error.Flush();
    }

    static void WriteStepStart(string sessionId, string messageId)
    {
        Console.WriteLine("{\"type\":\"step_start\",\"timestamp\":1700000000000,\"sessionID\":\"" + sessionId + "\",\"part\":{\"type\":\"step-start\",\"id\":\"step_s1\",\"sessionID\":\"" + sessionId + "\",\"messageID\":\"" + messageId + "\"}}");
        Console.Out.Flush();
    }

    static void WriteToolUse(string sessionId, string toolId, string messageId, string tool, string callId, string status, string content)
    {
        string stateJson = (status == "error")
            ? "{\"status\":\"error\",\"error\":\"" + EscapeJson(content) + "\"}"
            : "{\"status\":\"completed\",\"output\":\"" + EscapeJson(content) + "\"}";
        Console.WriteLine("{\"type\":\"tool_use\",\"timestamp\":1700000000100,\"sessionID\":\"" + sessionId + "\",\"part\":{\"type\":\"tool\",\"id\":\"" + toolId + "\",\"sessionID\":\"" + sessionId + "\",\"messageID\":\"" + messageId + "\",\"tool\":\"" + tool + "\",\"callID\":\"" + callId + "\",\"state\":" + stateJson + "}}");
        Console.Out.Flush();
    }

    static void WriteStepFinish(string sessionId, string reason, string messageId, int input, int output, int reasoning, int cacheRead, int cacheWrite, double cost)
    {
        string line = "{\"type\":\"step_finish\",\"timestamp\":1700000000200,\"sessionID\":\"" + sessionId + "\",\"part\":{\"type\":\"step-finish\",\"id\":\"step_f1\",\"sessionID\":\"" + sessionId + "\",\"messageID\":\"" + messageId + "\",\"reason\":\"" + reason + "\",\"cost\":" + cost.ToString(System.Globalization.CultureInfo.InvariantCulture) + ",\"tokens\":{\"input\":" + input + ",\"output\":" + output + ",\"reasoning\":" + reasoning + ",\"cache\":{\"read\":" + cacheRead + ",\"write\":" + cacheWrite + "}}}}";
        Console.WriteLine(line);
        Console.Out.Flush();
    }

    static string EnvEvidence()
    {
        return "{"
            + "\"LINEAR_API_KEY\":" + Present("LINEAR_API_KEY") + ","
            + "\"OPENAI_API_KEY\":" + Present("OPENAI_API_KEY") + ","
            + "\"ANTHROPIC_API_KEY\":" + Present("ANTHROPIC_API_KEY") + ","
            + "\"OPENCODE_PERMISSION\":" + Present("OPENCODE_PERMISSION") + ","
            + "\"OPENCODE_CONFIG_CONTENT\":" + Present("OPENCODE_CONFIG_CONTENT") + ","
            + "\"OPENCODE_DISABLE_PROJECT_CONFIG\":" + Present("OPENCODE_DISABLE_PROJECT_CONFIG") + ","
            + "\"OPENCODE_INHERITED_SENTINEL\":" + Present("OPENCODE_INHERITED_SENTINEL")
            + "}";
    }

    static string Present(string key)
    {
        string value = Environment.GetEnvironmentVariable(key);
        return string.IsNullOrEmpty(value) ? "false" : "true";
    }

    static string EncodeArgs(string[] args)
    {
        var sb = new StringBuilder();
        sb.Append("{\"args\":[");
        for (int i = 0; i < args.Length; i++)
        {
            if (i > 0) sb.Append(',');
            sb.Append(JsonString(args[i] ?? ""));
        }
        sb.Append("]}");
        return sb.ToString();
    }

    static string JsonString(string value)
    {
        var sb = new StringBuilder();
        sb.Append('"');
        foreach (char c in value)
        {
            if (c == '\\' || c == '"') sb.Append('\\');
            sb.Append(c);
        }
        sb.Append('"');
        return sb.ToString();
    }

    static string EscapeJson(string value)
    {
        if (value == null) return "";
        return value.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\n", "\\n").Replace("\r", "\\r");
    }
}

