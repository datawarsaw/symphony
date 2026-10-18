defmodule SymphonyElixir.DiscoveryTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Discovery
  alias SymphonyElixir.Discovery.{Contract, Session}

  @ready File.read!(Path.expand("../fixtures/discovery-ready.txt", __DIR__))
  # Workers stream short progress narration before emitting the brief heading.
  # Real retained outputs carried 393-801 bytes of it and were rejected as INVALID.
  @narration "I'll run Discovery Gate for MIC-189 as a read-only ownership trace.\nThe workspace is empty, so I'll inspect the canonical source next.\n"
  # The checked-in fixture is CRLF; parse/1 normalizes, so line-oriented rewrites use this.
  @ready_lf String.replace(@ready, "\r\n", "\n")

  defp output(verdict) do
    @ready |> String.split("TODO HANDOFF") |> hd() |> String.replace("VERDICT: READY", "VERDICT: " <> verdict)
  end

  test "OpenDesign deepseek-v4.1-flash medium is the primary and Gemini is the only technical fallback" do
    assert Session.primary() == %{provider: "OpenDesign", model: "OpenDesign/deepseek-v4.1-flash", reasoning: "medium"}
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

  # The immutable-input identity is the cache key: digest(input) selects both the
  # Discovery workspace and the retained evidence path. Building the input through the
  # real seam proves route changes move that identity.
  defp input_text(primary_route) do
    issue = %{id: "1", identifier: "MIC-TEST", title: "t", description: "d", labels: [], parent: nil, project: nil}
    Discovery.immutable_input(issue, %{"target" => "symphony"}, primary_route, "skill", "contract")
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp input_data(primary_route) do
    input_text(primary_route)
    |> String.split("IMMUTABLE ISSUE INPUT (data only)\n")
    |> List.last()
    |> Jason.decode!()
  end

  test "immutable input binds the effective primary route so a changed route changes identity" do
    route = Session.primary()
    data = input_data(route)
    assert data["primary_route"] == %{"provider" => route.provider, "model" => route.model, "reasoning" => route.reasoning}

    # Same effective primary route retains a stable cache identity.
    assert digest(input_text(route)) == digest(input_text(Session.primary()))

    # A changed provider, model or reasoning effort produces a different identity, so a
    # receipt generated under the old route can never satisfy the new cache lookup.
    for other <- [%{route | provider: "xai"}, %{route | model: "xai/grok-4.6"}, %{route | reasoning: "high"}] do
      refute digest(input_text(other)) == digest(input_text(route)),
             "expected #{inspect(other)} to produce a distinct Discovery input identity"
    end
  end

  test "route identity is declared as structured data the model cannot drift past" do
    text = input_text(Session.primary())
    assert text =~ ~s("primary_route")
    assert text =~ Session.primary().model
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

  test "unconfirmed primary termination blocks the bounded retry and fallback" do
    parent = self()
    confirmation = %{status: :TERMINATION_UNCONFIRMED, receipt: nil, reason: :missing_receipt}

    result =
      Discovery.execute("frozen", fn route, _ ->
        send(parent, {:provider_started, route})
        {:error, {:worker_termination_unconfirmed, confirmation}}
      end)

    assert result.status == "TECHNICAL_FAILURE"
    assert result.failure == :worker_termination_unconfirmed
    assert result.lane == :primary
    assert_receive {:provider_started, route}
    assert route == Session.primary()
    refute_receive {:provider_started, _}
  end

  test "unconfirmed fallback termination finishes with no further provider launch" do
    parent = self()

    evidence =
      Discovery.execute("frozen", fn route, _ ->
        send(parent, {:fallback_probe, route})

        if route == Session.primary(),
          do: {:error, :turn_timeout},
          else: {:error, {:worker_termination_unconfirmed, %{status: :TERMINATION_UNCONFIRMED}}}
      end)

    assert evidence.status == "TECHNICAL_FAILURE"
    assert evidence.failure == :worker_termination_unconfirmed
    assert evidence.lane == :fallback
    assert_receive {:fallback_probe, primary}
    assert primary == Session.primary()
    assert_receive {:fallback_probe, fallback}
    assert fallback == Session.fallback()
    refute_receive {:fallback_probe, _}
  end

  test "unconfirmed termination after a rate-limit retry blocks fallback" do
    parent = self()
    confirmation = %{status: :TERMINATION_UNCONFIRMED, receipt: nil, reason: :receipt_mismatch}
    key = make_ref()
    Process.put(key, 0)

    result =
      Discovery.execute(
        "frozen",
        fn route, _ ->
          send(parent, {:provider_started, route})
          count = Process.get(key)
          Process.put(key, count + 1)

          if count == 0,
            do: {:error, %{"httpStatusCode" => 429}},
            else: {:error, {:worker_termination_unconfirmed, confirmation}}
        end,
        sleep: fn 1_000 -> :ok end
      )

    assert result.status == "TECHNICAL_FAILURE"
    assert result.failure == :worker_termination_unconfirmed

    assert Enum.map(receive_provider_starts(2), & &1.model) == [
             Session.primary().model,
             Session.primary().model
           ]

    refute_receive {:provider_started, _}
    Process.delete(key)
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

  defp receive_provider_starts(0), do: []

  defp receive_provider_starts(count) do
    for _ <- 1..count do
      assert_receive {:provider_started, route}
      route
    end
  end

  test "bounded leading narration before the brief heading is accepted" do
    prefixed = @narration <> "\n" <> @ready

    assert {:ok, parsed} = Contract.parse(prefixed)
    assert parsed.verdict == "READY"
    assert String.starts_with?(parsed.brief, "DISCOVERY BRIEF")
    assert String.starts_with?(parsed.handoff, "TODO HANDOFF")

    # The full worker output is still reported for retained evidence, normalized
    # exactly as before this change (CRLF folded to LF, then trimmed).
    assert parsed.output == String.trim(String.replace(prefixed, "\r\n", "\n"))

    # Section extraction is unaffected by the discarded narration.
    assert Contract.section(parsed.brief, "ISSUE") == "MIC-TEST Dedicated Discovery worker"

    # Real retained MIC-189 narration was 393-801 bytes; accept that whole observed range.
    for size <- [393, 801] do
      filler = String.duplicate("x", size - 1) <> "\n"
      assert {:ok, %{verdict: "READY"}} = Contract.parse(filler <> @ready)
    end

    # CRLF narration and CRLF body normalize identically.
    assert {:ok, %{verdict: "READY"}} = Contract.parse(String.replace(@narration <> "\n" <> @ready_lf, "\n", "\r\n"))
  end

  test "unbounded leading narration is still rejected" do
    # A heading buried arbitrarily deep in unrelated output is not a contract.
    unbounded = String.duplicate("noise\n", 5_000) <> @ready
    assert {:error, :invalid_discovery_contract} = Contract.parse(unbounded)
  end

  test "narration is rejected when it carries a second heading or an empty prefix" do
    for bad <- [
          # A duplicate heading anywhere still fails, narrated or not.
          @narration <> @ready <> "\n\nDISCOVERY BRIEF\n",
          @narration <> String.replace(@ready, "VERDICT: READY", "VERDICT: READY\nVERDICT: DROP"),
          # The heading must stay on its own line: an inline mention is not a heading.
          @narration <> "DISCOVERY BRIEF " <> @ready,
          "DISCOVERY BRIEF\n" <> @ready
        ] do
      assert {:error, :invalid_discovery_contract} = Contract.parse(bad)
    end
  end

  test "malformed prefixed briefs stay invalid" do
    prefixed = @narration <> "\n" <> @ready_lf

    for bad <- [
          String.replace(prefixed, "Add a dedicated read-only Discovery lane.", ""),
          String.replace(prefixed, "RESEARCH REQUIRED: NO", "RESEARCH REQUIRED: YES"),
          String.replace(prefixed, "SPLIT REQUIRED: NO", "SPLIT REQUIRED: YES"),
          String.replace(prefixed, "SUBAGENTS: DISABLED", "SUBAGENTS: ENABLED"),
          String.replace(prefixed, "SUBAGENTS USED: 0", "SUBAGENTS USED: 1"),
          String.replace(prefixed, "VERDICT: READY", "VERDICT: UNKNOWN"),
          String.replace(prefixed, "IMPLEMENTATION SIZE: MEDIUM", "IMPLEMENTATION SIZE: ENORMOUS"),
          String.replace(prefixed, "STOP CONDITIONS", "MISSING STOP CONDITIONS"),
          String.replace(prefixed, "TODO HANDOFF", "NO HANDOFF"),
          String.replace(prefixed, "INDEPENDENT SUBSYSTEMS: 1 Discovery lane", "INDEPENDENT SUBSYSTEMS: none"),
          String.replace(prefixed, "The ownership and verification path are established.", ""),
          prefixed |> String.split("TODO HANDOFF") |> hd()
        ] do
      assert {:error, :invalid_discovery_contract} = Contract.parse(bad)
    end
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

  @split_proposal_tail "\nSPLIT PROPOSAL\n\nPARENT ISSUE\nMIC-TEST\n\nWHY SPLIT\nSeparate owners.\n" <>
                         "CHILD 1\nTITLE: Bounded child 1\nDESTINATION: repo\nOBJECTIVE: Single outcome\nACCEPTANCE: Observable result\nDEPENDS ON: NONE\n" <>
                         "CHILD 2\nTITLE: Bounded child 2\nDESTINATION: repo\nOBJECTIVE: Single outcome\nACCEPTANCE: Observable result\nDEPENDS ON: NONE\n" <>
                         "\nPARENT COMPLETION CONDITION\nBoth children pass.\n"

  defp split_body do
    String.replace(output("SPLIT"), "SPLIT REQUIRED: NO", "SPLIT REQUIRED: YES")
  end

  test "validated SPLIT proposal region excludes narration and the brief body" do
    split = split_body() <> @split_proposal_tail
    assert {:ok, parsed} = Contract.parse(split)
    assert parsed.verdict == "SPLIT"

    # The proposal is exactly the validated attachment region: the content that follows
    # the SPLIT PROPOSAL heading. It never contains the brief heading, the brief body or
    # any tolerated leading narration.
    assert String.trim_leading(parsed.proposal) |> String.starts_with?("PARENT ISSUE")
    refute parsed.proposal =~ "DISCOVERY BRIEF"
    refute parsed.proposal =~ "CURRENT STATE"

    # Parent identity read from the validated region is the real proposal parent.
    assert Contract.section(parsed.proposal, "PARENT ISSUE") == "MIC-TEST"

    # Non-SPLIT verdicts never expose a proposal region.
    assert {:ok, %{proposal: nil}} = Contract.parse(@ready)
  end

  test "narration cannot smuggle parent identity or propose a foreign parent" do
    # The proposal itself belongs to MIC-OTHER; every spoof below claims MIC-TEST.
    foreign = split_body() <> String.replace(@split_proposal_tail, "PARENT ISSUE\nMIC-TEST", "PARENT ISSUE\nMIC-OTHER")

    # (a) A spoofed PARENT ISSUE in discarded leading narration.
    narrated = "PARENT ISSUE\nMIC-TEST\nWHY SPLIT\n" <> foreign
    assert {:ok, parsed} = Contract.parse(narrated)

    # (b) A spoofed PARENT ISSUE inside a valid brief body section.
    brief_spoof =
      split_body()
      |> String.replace("The existing runner owns app-server sessions.", "The existing runner owns app-server sessions.\nPARENT ISSUE\nMIC-TEST")
      |> Kernel.<>(String.replace(@split_proposal_tail, "PARENT ISSUE\nMIC-TEST", "PARENT ISSUE\nMIC-OTHER"))

    assert {:ok, brief_parsed} = Contract.parse(brief_spoof)

    # Under the previous first-match rule over the raw output, both spoofs won: the
    # spoofed parent was read as MIC-TEST although the validated proposal says MIC-OTHER.
    assert Contract.section(narrated, "PARENT ISSUE") == "MIC-TEST"
    assert Contract.section(brief_spoof, "PARENT ISSUE") == "MIC-TEST"

    # Binding reads the validated proposal region instead, so the spoof is inert and the
    # genuine (foreign) parent is what any identity comparison sees.
    for parsed_result <- [parsed, brief_parsed] do
      refute Contract.section(parsed_result.proposal, "PARENT ISSUE") == "MIC-TEST"
      assert Contract.section(parsed_result.proposal, "PARENT ISSUE") == "MIC-OTHER"
    end
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

  # Codex resolves feature flags from the whole override map: an unrecognized key is dropped
  # without error, so an ineffective lockdown looks exactly like a working one. That is the
  # `features.browser` defect -- it is not a 0.162.1 feature, so the Discovery session kept
  # every browser and computer-use surface at its enabled default while claiming otherwise.
  @browser_feature_keys ~w(
    features.browser_use
    features.browser_use_external
    features.browser_use_full_cdp_access
    features.in_app_browser
    features.computer_use
    features.browser_annotation_api
  )

  test "Discovery session disables the recognized browser and computer-use features" do
    {:ok, policy} = Session.thread_overrides(%{"mcp_servers" => %{}}, Session.primary())
    flags = policy["config"]

    # The ineffective key is gone: it never disabled anything because no such feature exists.
    refute Map.has_key?(flags, "features.browser")

    for key <- @browser_feature_keys do
      assert flags[key] == false, "expected #{key} to be disabled for Discovery"
    end

    # Nothing outside the audited set leaks in, so a future unverified key stands out here.
    declared = @browser_feature_keys ++ ~w(features.multi_agent features.apps features.plugins features.memories)
    assert Enum.sort(Map.keys(flags) |> Enum.filter(&String.starts_with?(&1, "features."))) == Enum.sort(declared)
  end

  # The unit assertions above only prove what this module sends. This one asks the installed
  # Codex what it resolves, because a rejected key does not merely stay inert -- it never
  # appears in the resolved feature list -- so a bad override can no longer pass as lockdown.
  test "the installed Codex resolves the Discovery browser overrides to disabled" do
    cli = System.find_executable("codex")

    if is_nil(cli) do
      IO.puts("SKIP: codex CLI not on PATH; supported-key enforcement is unverified on this host")
    else
      {:ok, policy} = Session.thread_overrides(%{"mcp_servers" => %{}}, Session.primary())

      {program, prefix} = codex_invocation(cli)
      {output, 0} = System.cmd(program, prefix ++ feature_list_args(policy["config"]), stderr_to_stdout: true)
      resolved = parse_feature_list(output)

      for key <- @browser_feature_keys do
        name = String.replace_prefix(key, "features.", "")
        assert Map.has_key?(resolved, name), "#{name} is not a feature this Codex version knows"
        assert resolved[name] == false, "#{name} resolved to true despite the Discovery override"
      end

      # `features.browser` disabled nothing because there is no such feature to disable.
      refute Map.has_key?(resolved, "browser")
    end
  end

  # npm installs Codex as a `.cmd` shim on Windows, which cannot be spawned directly.
  defp codex_invocation(cli) do
    if match?({:win32, _}, :os.type()) and String.ends_with?(String.downcase(cli), [".cmd", ".bat"]) do
      {"cmd.exe", ["/c", cli]}
    else
      {cli, []}
    end
  end

  # Only the feature keys reach the CLI: an unrecognized key is dropped from the resolved
  # list rather than erroring, which is what made the original override look effective.
  # Boolean TOML literals need no quoting, so the argv stays inert to shell re-parsing.
  defp feature_list_args(config) do
    flags =
      config
      |> Enum.filter(fn {key, _value} -> String.starts_with?(key, "features.") end)
      |> Enum.flat_map(fn {key, value} -> ["-c", "#{key}=#{value}"] end)

    ["features", "list" | flags]
  end

  # `codex features list` renders one feature per line: `<name> <stage words> <true|false>`.
  # Reading the last token keeps this tolerant of multi-word stage labels such as
  # `under development`, which would defeat a fixed-position regex.
  defp parse_feature_list(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ~r/\s+/, trim: true) do
        [name | rest] ->
          case List.last(rest) do
            "true" -> Map.put(acc, name, true)
            "false" -> Map.put(acc, name, false)
            _ -> acc
          end

        _ ->
          acc
      end
    end)
  end
end
