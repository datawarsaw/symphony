defmodule SymphonyElixir.DiscoveryTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Discovery
  alias SymphonyElixir.Discovery.{Contract, Session}

  @ready File.read!(Path.expand("../fixtures/discovery-ready.txt", __DIR__))

  defp output(verdict) do
    @ready |> String.split("TODO HANDOFF") |> hd() |> String.replace("VERDICT: READY", "VERDICT: " <> verdict)
  end

  test "Grok medium is the primary and Gemini is the only technical fallback" do
    assert Session.primary() == %{provider: "xai", model: "xai/grok-4.6", reasoning: "medium"}
    assert Session.fallback().model == "google-antigravity/gemini-3.8-flash"
    parent = self()

    result =
      Discovery.execute(@ready, fn route, input ->
        send(parent, {route, input})
        {:ok, @ready}
      end)

    assert result.status == "READY"
    assert result.lane == :primary
    assert_receive {route, @ready}
    assert route == Session.primary()
    refute_receive _
  end

  test "successful non-READY verdicts and malformed output never trigger fallback" do
    for verdict <- ~w(NEEDS_RESEARCH NEEDS_DECISION BLOCKED DROP) do
      result =
        Discovery.execute("immutable", fn route, _ ->
          assert route == Session.primary()
          {:ok, output(verdict)}
        end)

      assert result.status == verdict
      assert result.output == output(verdict)
    end

    assert Discovery.execute("same", fn _, _ -> {:ok, "VERDICT: READY"} end).status == "INVALID"
  end

  test "rate limit retries once then falls back using byte-identical immutable input" do
    key = make_ref()
    Process.put(key, [])
    input = "immutable source snapshot\nincluding CRLF\r\n"

    result =
      Discovery.execute(
        input,
        fn route, received ->
          Process.put(key, [{route.model, received} | Process.get(key)])
          if route == Session.primary(), do: {:error, %{"httpStatusCode" => 429}}, else: {:ok, output("BLOCKED")}
        end,
        sleep: fn 1_000 -> :ok end
      )

    assert result.status == "BLOCKED"
    assert result.lane == :fallback
    assert result.fallback_reason == :rate_limit

    assert Enum.reverse(Process.get(key)) == [
             {Session.primary().model, input},
             {Session.primary().model, input},
             {Session.fallback().model, input}
           ]
  end

  test "successful bounded retry does not fall back" do
    key = make_ref()
    Process.put(key, 0)

    result =
      Discovery.execute(
        "frozen",
        fn route, _ ->
          assert route == Session.primary()
          count = Process.get(key)
          Process.put(key, count + 1)
          if count == 0, do: {:error, %{"code" => "rate_limit_exceeded"}}, else: {:ok, @ready}
        end,
        sleep: fn _ -> :ok end
      )

    assert result.status == "READY"
    assert result.lane == :primary
  end

  test "only structured technical failures qualify" do
    for error <- [%{"httpStatusCode" => 401}, %{"code" => "model_not_found"}, %{"code" => "insufficient_quota"}, %{"httpStatusCode" => 503}, :turn_timeout, {:port_exit, 1}] do
      assert Session.technical_failure(error)
    end

    for error <- [:approval_required, :invalid_discovery_contract, %{"message" => "quota"}, %{"code" => "invalid_request"}] do
      assert Session.technical_failure(error) == nil
    end

    result =
      Discovery.execute("frozen", fn route, _ ->
        assert route == Session.primary()
        {:error, :approval_required}
      end)

    assert result.lane == :primary
  end

  test "READY requires a full handoff and unsplit bounded contract" do
    assert {:ok, %{verdict: "READY", handoff: handoff}} = Contract.parse(@ready)
    assert String.starts_with?(handoff, "TODO HANDOFF")
    assert {:ok, _} = Contract.parse(String.replace(@ready, "IMPLEMENTATION SIZE: MEDIUM", "IMPLEMENTATION SIZE: LARGE"))
    assert {:ok, _} = Contract.parse(String.replace(@ready, "EXPECTED CONTEXT SURFACE: BOUNDED", "EXPECTED CONTEXT SURFACE: BROAD"))

    for bad <- [
          String.replace(@ready, "Add a dedicated read-only Discovery lane.", ""),
          String.replace(@ready, "Add a dedicated read-only Discovery lane.", "<objective>"),
          String.replace(@ready, "RESEARCH REQUIRED: NO", "RESEARCH REQUIRED: YES"),
          @ready
          |> String.replace("IMPLEMENTATION SIZE: MEDIUM", "IMPLEMENTATION SIZE: LARGE")
          |> String.replace("EXPECTED CONTEXT SURFACE: BOUNDED", "EXPECTED CONTEXT SURFACE: BROAD"),
          output("READY"),
          String.replace(@ready, "SUBAGENTS: DISABLED", "SUBAGENTS: ENABLED"),
          String.replace(@ready, "SPLIT REQUIRED: NO", "SPLIT REQUIRED: YES"),
          String.replace(@ready, "STOP CONDITIONS", "MISSING STOP CONDITIONS"),
          String.replace(@ready, "VERDICT: READY", "VERDICT: READY\nVERDICT: DROP")
        ] do
      assert {:error, :invalid_discovery_contract} = Contract.parse(bad)
    end
  end

  test "SPLIT requires child proposals and never supplies an implementation handoff" do
    split = String.replace(output("SPLIT"), "SPLIT REQUIRED: NO", "SPLIT REQUIRED: YES")
    assert {:error, _} = Contract.parse(split)

    split =
      split <>
        "\nSPLIT PROPOSAL\n\nPARENT ISSUE\nMIC-TEST\n\nWHY SPLIT\nSeparate owners.\n" <>
        Enum.map_join(1..2, "\n", fn n -> "\nCHILD #{n}\nTITLE: Bounded child #{n}\nDESTINATION: repo\nOBJECTIVE: Single outcome\nACCEPTANCE: Observable result\nDEPENDS ON: NONE\n" end) <>
        "\nPARENT COMPLETION CONDITION\nBoth children pass.\n"

    assert {:ok, %{verdict: "SPLIT", handoff: nil}} = Contract.parse(split)

    result =
      Discovery.execute("input", fn route, _ ->
        assert route == Session.primary()
        {:ok, split}
      end)

    assert result.status == "SPLIT"
  end

  test "Discovery session disables inherited mutation and subagent integrations" do
    {:ok, policy} = Session.thread_overrides(%{"mcp_servers" => %{"linear" => %{}, "shell" => %{}}}, Session.primary())
    assert policy["sandbox"] == "read-only"
    assert policy["approvalPolicy"] == "never"
    assert policy["approvalsReviewer"] == "user"
    assert policy["dynamicTools"] == []
    assert policy["selectedCapabilityRoots"] == []

    for key <- ["mcp_servers.linear.enabled", "mcp_servers.shell.enabled", "features.multi_agent", "features.apps", "features.plugins"] do
      assert policy["config"][key] == false
    end

    assert {:error, _} = Session.thread_overrides(%{"mcp_servers" => %{"unsafe.name" => %{}}}, Session.primary())
  end
end
