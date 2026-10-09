using System;
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

        if (sleepMs > 0)
        {
            Thread.Sleep(sleepMs);
        }

        if (mode == "success")
        {
            Console.WriteLine("{\"type\":\"step_start\",\"timestamp\":1700000000000,\"sessionID\":\"ses_mock_123\"}");
            Console.WriteLine("{\"type\":\"tool_use\",\"timestamp\":1700000000100,\"sessionID\":\"ses_mock_123\",\"part\":{\"tool\":\"read\",\"callID\":\"call_99\",\"state\":{\"status\":\"completed\",\"output\":\"file contents\"},\"messageID\":\"msg_01\"}}");
            Console.WriteLine("{\"type\":\"step_finish\",\"timestamp\":1700000000200,\"sessionID\":\"ses_mock_123\",\"part\":{\"tokens\":{\"input\":100,\"output\":200,\"reasoning\":25,\"cache\":{\"read\":50,\"write\":10}},\"cost\":0.005,\"messageID\":\"msg_01\"}}");
            Console.WriteLine("{\"type\":\"session.status\",\"timestamp\":1700000000300,\"sessionID\":\"ses_mock_123\",\"status\":{\"type\":\"idle\"}}");
            return 0;
        }
        else if (mode == "error")
        {
            Console.WriteLine("{\"type\":\"error\",\"timestamp\":1700000000000,\"sessionID\":\"ses_mock_123\",\"error\":{\"name\":\"ModelNotFoundError\",\"data\":{\"message\":\"Model not found: test/not-found\"} }}");
            return 1;
        }
        else if (mode == "hang")
        {
            Console.WriteLine("{\"type\":\"step_start\",\"timestamp\":1700000000000,\"sessionID\":\"ses_mock_123\"}");
            Thread.Sleep(60000);
            return 0;
        }

        return 0;
    }
}
