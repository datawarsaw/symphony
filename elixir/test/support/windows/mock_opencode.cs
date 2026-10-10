using System;
using System.IO;
using System.Text;
using System.Threading;

class MockOpenCode
{
    static int Main(string[] args)
    {
        string mode = "success";
        int sleepMs = 0;

        foreach (var arg in args)
        {
            if (arg.StartsWith("--mock-mode=")) mode = arg.Substring(12);
            if (arg.StartsWith("--mock-sleep=")) int.TryParse(arg.Substring(13), out sleepMs);
        }

        string controlPath = Path.Combine(Directory.GetCurrentDirectory(), "opencode-mock-control.txt");
        if (File.Exists(controlPath))
        {
            foreach (string line in File.ReadAllLines(controlPath))
            {
                if (line.StartsWith("mode=")) mode = line.Substring(5).Trim();
            }
        }

        if (sleepMs > 0) Thread.Sleep(sleepMs);

        if (mode == "stdin")
        {
            using (Stream stdin = Console.OpenStandardInput())
            {
                byte[] buffer = new byte[256];
                while (stdin.Read(buffer, 0, buffer.Length) > 0) { }
            }
            WriteSuccess();
            return 0;
        }

        if (mode == "env")
        {
            File.WriteAllText(
                Path.Combine(Directory.GetCurrentDirectory(), "opencode-child-evidence.json"),
                EnvEvidence());
            WriteSuccess();
            return 0;
        }

        if (mode == "argv")
        {
            File.WriteAllText(
                Path.Combine(Directory.GetCurrentDirectory(), "opencode-argv.json"),
                EncodeArgs(args));
            WriteSuccess();
            return 0;
        }

        if (mode == "partial")
        {
            WriteStepStart("msg_01");
            return 0;
        }

        if (mode == "malformed")
        {
            Console.WriteLine("not-json-at-all");
            WriteSuccess();
            return 0;
        }

        if (mode == "malformed-secret")
        {
            Console.WriteLine("{\"type\":\"tool_use\",\"broken\":\"sk-ant-api03-abcdefghijklmnopqrstuvwxyz LINEAR_API_KEY=lin_api_abcdefghijklmnopqrstuvwxyz");
            WriteSuccess();
            return 0;
        }

        if (mode == "tool-calls-only")
        {
            WriteStepStart("msg_01");
            WriteStepFinish("tool-calls", "msg_01", 40, 60, 10, 5, 5, 0.002);
            return 0;
        }

        if (mode == "multi-step")
        {
            WriteStepStart("msg_01");
            WriteStepFinish("tool-calls", "msg_01", 40, 60, 10, 5, 5, 0.002);
            Console.WriteLine("{\"type\":\"tool_use\",\"timestamp\":1700000000150,\"sessionID\":\"ses_mock_123\",\"part\":{\"type\":\"tool\",\"id\":\"toolu_01\",\"sessionID\":\"ses_mock_123\",\"messageID\":\"msg_01\",\"tool\":\"read\",\"callID\":\"call_99\",\"state\":{\"status\":\"completed\",\"output\":\"file contents\"}}}");
            WriteStepStart("msg_02");
            WriteStepFinish("stop", "msg_02", 60, 90, 15, 10, 5, 0.003);
            return 0;
        }

        if (mode == "tool-error")
        {
            Console.WriteLine("{\"type\":\"tool_use\",\"timestamp\":1700000000100,\"sessionID\":\"ses_mock_123\",\"part\":{\"type\":\"tool\",\"id\":\"toolu_err\",\"sessionID\":\"ses_mock_123\",\"messageID\":\"msg_err\",\"tool\":\"read\",\"callID\":\"call_err\",\"state\":{\"status\":\"error\",\"error\":\"permission denied\"}}}");
            WriteStepFinish("stop", "msg_err", 100, 200, 25, 50, 10, 0.005);
            return 0;
        }

        if (mode == "secret")
        {
            Console.WriteLine("{\"type\":\"tool_use\",\"timestamp\":1700000000100,\"sessionID\":\"ses_mock_123\",\"part\":{\"type\":\"tool\",\"id\":\"toolu_secret\",\"sessionID\":\"ses_mock_123\",\"messageID\":\"msg_secret\",\"tool\":\"read\",\"callID\":\"call_secret\",\"state\":{\"status\":\"completed\",\"output\":\"sk-ant-api03-abcdefghijklmnopqrstuvwxyz LINEAR_API_KEY=lin_api_abcdefghijklmnopqrstuvwxyz\"}}}");
            WriteStepFinish("stop", "msg_secret", 10, 20, 0, 0, 0, 0.0);
            Console.Error.WriteLine("stderr sk-ant-api03-abcdefghijklmnopqrstuvwxyz LINEAR_API_KEY=lin_api_abcdefghijklmnopqrstuvwxyz");
            return 0;
        }

        if (mode == "success")
        {
            WriteSuccess();
            return 0;
        }

        if (mode == "error")
        {
            Console.WriteLine("{\"type\":\"error\",\"timestamp\":1700000000000,\"sessionID\":\"ses_mock_123\",\"error\":{\"name\":\"ModelNotFoundError\",\"data\":{\"message\":\"Model not found: test/not-found\"} }}");
            return 1;
        }

        if (mode == "hang")
        {
            WriteStepStart("msg_01");
            Console.Out.Flush();
            Thread.Sleep(60000);
            return 0;
        }

        return 0;
    }

    static void WriteSuccess()
    {
        WriteStepStart("msg_01");
        Console.WriteLine("{\"type\":\"tool_use\",\"timestamp\":1700000000100,\"sessionID\":\"ses_mock_123\",\"part\":{\"type\":\"tool\",\"id\":\"toolu_01\",\"sessionID\":\"ses_mock_123\",\"messageID\":\"msg_01\",\"tool\":\"read\",\"callID\":\"call_99\",\"state\":{\"status\":\"completed\",\"output\":\"file contents\"}}}");
        WriteStepFinish("stop", "msg_01", 100, 200, 25, 50, 10, 0.005);
        Console.Error.WriteLine("not-json-stderr-marker");
    }

    static void WriteStepStart(string messageId)
    {
        Console.WriteLine("{\"type\":\"step_start\",\"timestamp\":1700000000000,\"sessionID\":\"ses_mock_123\",\"part\":{\"type\":\"step-start\",\"id\":\"step_s1\",\"sessionID\":\"ses_mock_123\",\"messageID\":\"" + messageId + "\"}}");
    }

    static void WriteStepFinish(string reason, string messageId, int input, int output, int reasoning, int cacheRead, int cacheWrite, double cost)
    {
        Console.WriteLine("{\"type\":\"step_finish\",\"timestamp\":1700000000200,\"sessionID\":\"ses_mock_123\",\"part\":{\"type\":\"step-finish\",\"id\":\"step_f1\",\"sessionID\":\"ses_mock_123\",\"messageID\":\"" + messageId + "\",\"reason\":\"" + reason + "\",\"cost\":" + cost.ToString(System.Globalization.CultureInfo.InvariantCulture) + ",\"tokens\":{\"input\":" + input + ",\"output\":" + output + ",\"reasoning\":" + reasoning + ",\"cache\":{\"read\":" + cacheRead + ",\"write\":" + cacheWrite + "}}}}");
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
}
