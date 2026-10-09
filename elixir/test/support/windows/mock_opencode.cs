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
            Console.WriteLine("{\"type\":\"step_start\",\"timestamp\":1700000000000,\"sessionID\":\"ses_mock_123\"}");
            return 0;
        }

        if (mode == "malformed")
        {
            Console.WriteLine("not-json-at-all");
            WriteIdle();
            return 0;
        }

        if (mode == "tool-error")
        {
            Console.WriteLine("{\"type\":\"tool_use\",\"timestamp\":1700000000100,\"sessionID\":\"ses_mock_123\",\"part\":{\"tool\":\"read\",\"callID\":\"call_err\",\"state\":{\"status\":\"error\",\"error\":\"permission denied\"},\"messageID\":\"msg_err\"}}");
            WriteIdle();
            return 0;
        }

        if (mode == "secret")
        {
            Console.WriteLine("{\"type\":\"tool_use\",\"timestamp\":1700000000100,\"sessionID\":\"ses_mock_123\",\"part\":{\"tool\":\"read\",\"callID\":\"call_secret\",\"state\":{\"status\":\"completed\",\"output\":\"sk-ant-api03-abcdefghijklmnopqrstuvwxyz LINEAR_API_KEY=lin_api_abcdefghijklmnopqrstuvwxyz\"},\"messageID\":\"msg_secret\"}}");
            Console.Error.WriteLine("stderr sk-ant-api03-abcdefghijklmnopqrstuvwxyz LINEAR_API_KEY=lin_api_abcdefghijklmnopqrstuvwxyz");
            WriteIdle();
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
            Console.WriteLine("{\"type\":\"step_start\",\"timestamp\":1700000000000,\"sessionID\":\"ses_mock_123\"}");
            Console.Out.Flush();
            Thread.Sleep(60000);
            return 0;
        }

        return 0;
    }

    static void WriteSuccess()
    {
        Console.WriteLine("{\"type\":\"step_start\",\"timestamp\":1700000000000,\"sessionID\":\"ses_mock_123\"}");
        Console.WriteLine("{\"type\":\"tool_use\",\"timestamp\":1700000000100,\"sessionID\":\"ses_mock_123\",\"part\":{\"tool\":\"read\",\"callID\":\"call_99\",\"state\":{\"status\":\"completed\",\"output\":\"file contents\"},\"messageID\":\"msg_01\"}}");
        Console.WriteLine("{\"type\":\"step_finish\",\"timestamp\":1700000000200,\"sessionID\":\"ses_mock_123\",\"part\":{\"tokens\":{\"input\":100,\"output\":200,\"reasoning\":25,\"cache\":{\"read\":50,\"write\":10}},\"cost\":0.005,\"messageID\":\"msg_01\"}}");
        WriteIdle();
        Console.Error.WriteLine("not-json-stderr-marker");
    }

    static void WriteIdle()
    {
        Console.WriteLine("{\"type\":\"session.status\",\"timestamp\":1700000000300,\"sessionID\":\"ses_mock_123\",\"status\":{\"type\":\"idle\"}}");
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
