defmodule SymphonyElixir.WorkerEventTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.WorkerEvent

  describe "new/1 and defaults" do
    test "creates a worker event with expected defaults" do
      event = WorkerEvent.new()

      assert event.event == :activity
      assert event.harness == :generic
      assert event.timestamp == nil
      refute WorkerEvent.activity?(event)
      assert event.terminal? == false
      assert event.payload == %{}
    end

    test "accepts custom fields and computes terminal? for terminal events" do
      completed = WorkerEvent.new(event: :turn_completed, session_id: "ses-1")
      assert completed.terminal? == true
      assert completed.session_id == "ses-1"

      failed = WorkerEvent.new(event: :failed)
      assert failed.terminal? == true

      custom = WorkerEvent.new(event: :activity, terminal?: true)
      assert custom.terminal? == true
    end
  end

  describe "from_codex/2" do
    test "normalizes legacy Codex notification messages" do
      now = DateTime.utc_now()

      codex_msg = %{
        event: :notification,
        timestamp: now,
        session_id: "thread-1-turn-1",
        payload: %{method: "item/created"},
        model: "gpt-4o",
        reasoning_effort: "high",
        route_source: :open_code,
        codex_app_server_pid: 1234
      }

      event = WorkerEvent.from_codex(codex_msg)

      assert event.event == :notification
      assert event.harness == :codex
      assert event.session_id == "thread-1-turn-1"
      assert event.timestamp == now
      assert event.terminal? == false
      assert event.metadata.model == "gpt-4o"
      assert event.metadata.reasoning_effort == "high"
      assert event.metadata.route_source == :open_code
      assert event.metadata.codex_app_server_pid == 1234
    end

    test "normalizes Codex turn_completed with terminal? true" do
      codex_msg = %{
        event: :turn_completed,
        timestamp: DateTime.utc_now(),
        payload: %{method: "turn/completed"},
        usage: %{"input_tokens" => 40, "output_tokens" => 80, "total_tokens" => 120}
      }

      event = WorkerEvent.from_codex(codex_msg)

      assert event.event == :turn_completed
      assert event.terminal? == true
      assert event.usage == %{input_tokens: 40, output_tokens: 80, total_tokens: 120}
    end
  end

  describe "from_opencode/2 and OpenCode JSONL event taxonomy" do
    test "normalizes step_start as intermediate activity" do
      raw = ~s({"type":"step_start","timestamp":1728490000,"sessionID":"ses-opencode-1"})

      event = WorkerEvent.from_opencode(raw)

      assert event.event == :step_start
      assert event.harness == :opencode
      assert event.session_id == "ses-opencode-1"
      assert event.terminal? == false
      assert WorkerEvent.intermediate?(event)
      assert WorkerEvent.activity?(event)
    end

    test "normalizes step_finish with tokens as intermediate event, NOT terminal" do
      raw = ~s({
        "type": "step_finish",
        "timestamp": 1728490005,
        "sessionID": "ses-opencode-1",
        "part": {
          "messageID": "msg-step-1",
          "tokens": {
            "input": 150,
            "output": 350,
            "reasoning": 50,
            "cache": {"read": 20, "write": 10}
          },
          "cost": 0.0045
        }
      })

      event = WorkerEvent.from_opencode(raw)

      assert event.event == :step_finish
      assert event.harness == :opencode
      assert event.session_id == "ses-opencode-1"
      assert event.message_id == "msg-step-1"
      # Critical requirement: step_finish must NOT be terminal!
      assert event.terminal? == false
      assert WorkerEvent.intermediate?(event)
      assert WorkerEvent.activity?(event)

      assert event.usage == %{
               input_tokens: 150,
               output_tokens: 350,
               total_tokens: 500,
               reasoning_tokens: 50,
               cache_read_tokens: 20,
               cache_write_tokens: 10,
               cost: 0.0045
             }
    end

    test "normalizes tool_use with call details and state" do
      raw = ~s({
        "type": "tool_use",
        "timestamp": 1728490002,
        "sessionID": "ses-opencode-1",
        "part": {
          "tool": "file_reader",
          "callID": "call-42",
          "messageID": "msg-tool-1",
          "state": {
            "status": "completed",
            "output": "contents of file"
          }
        }
      })

      event = WorkerEvent.from_opencode(raw)

      assert event.event == :tool_use
      assert event.terminal? == false
      assert event.session_id == "ses-opencode-1"
      assert event.message_id == "msg-tool-1"
      assert event.payload.tool == "file_reader"
      assert event.payload.call_id == "call-42"
      assert event.payload.status == "completed"
      assert event.payload.output == "contents of file"
    end

    test "normalizes text and reasoning streams as intermediate activity" do
      text_raw = ~s({"type":"text","sessionID":"s1","part":{"text":"hello"}})
      text_event = WorkerEvent.from_opencode(text_raw)
      assert text_event.event == :text
      assert text_event.terminal? == false
      assert text_event.payload.text == "hello"

      reasoning_raw = ~s({"type":"reasoning","sessionID":"s1","part":{"text":"thinking..."}})
      reasoning_event = WorkerEvent.from_opencode(reasoning_raw)
      assert reasoning_event.event == :reasoning
      assert reasoning_event.terminal? == false
      assert reasoning_event.payload.text == "thinking..."
    end

    test "does not treat session.status idle as CLI completion" do
      raw = ~s({
        "type": "session.status",
        "timestamp": 1728490010,
        "sessionID": "ses-opencode-1",
        "properties": {
          "status": {"type": "idle"}
        }
      })

      event = WorkerEvent.from_opencode(raw)

      assert event.event == :session_status
      refute event.event == :turn_completed
      assert event.terminal? == false
      assert event.metadata.successful_completion? == false
      assert event.session_id == "ses-opencode-1"
    end

    test "step_finish reasons follow the OpenCode CLI contract" do
      for reason <- ["stop", "length", "content-filter", "unknown"] do
        event = step_finish(reason)
        assert event.event == :step_finish
        assert event.terminal?
        assert event.metadata.finish_reason == reason
        assert event.metadata.successful_completion? == false
      end

      for reason <- ["tool-calls", "error"] do
        event = step_finish(reason)
        refute event.terminal?
        assert event.metadata.successful_completion? == false
      end

      missing = step_finish(nil)
      refute missing.terminal?
      assert missing.metadata.successful_completion? == false
    end

    test "normalizes session.status error as terminal failure" do
      raw = ~s({
        "type": "session.status",
        "timestamp": 1728490010,
        "sessionID": "ses-opencode-1",
        "status": {"type": "error"}
      })

      event = WorkerEvent.from_opencode(raw)

      assert event.event == :failed
      assert event.terminal? == true
    end

    test "normalizes session.status busy/running as intermediate activity" do
      raw = ~s({
        "type": "session.status",
        "status": {"type": "running"}
      })

      event = WorkerEvent.from_opencode(raw)

      assert event.event == :activity
      assert event.terminal? == false
    end

    test "normalizes error and session.error as terminal failure" do
      raw = ~s({"type":"error","error":"fatal context overflow"})
      event = WorkerEvent.from_opencode(raw)

      assert event.event == :error
      assert event.terminal? == true
    end
  end

  describe "timestamp normalization" do
    test "normalizes DateTime directly" do
      dt = ~U[2026-10-09 18:30:00Z]
      assert WorkerEvent.normalize_timestamp(dt) == dt
    end

    test "normalizes unix milliseconds" do
      ts_ms = 1_728_490_000_123
      dt = WorkerEvent.normalize_timestamp(ts_ms)
      assert %DateTime{} = dt
      assert DateTime.to_unix(dt, :millisecond) == ts_ms
    end

    test "normalizes unix seconds" do
      ts_s = 1_728_490_000
      dt = WorkerEvent.normalize_timestamp(ts_s)
      assert %DateTime{} = dt
      assert DateTime.to_unix(dt, :second) == ts_s
    end

    test "normalizes ISO8601 string" do
      iso = "2026-10-09T18:30:00Z"
      dt = WorkerEvent.normalize_timestamp(iso)
      assert %DateTime{} = dt
      assert DateTime.to_iso8601(dt) == iso
    end

    test "does not treat missing or invalid timestamps as fresh liveness" do
      assert WorkerEvent.normalize_timestamp(nil) == nil
      assert WorkerEvent.normalize_timestamp("not-a-date") == nil
      assert WorkerEvent.normalize_timestamp(0) == nil

      event = WorkerEvent.new(timestamp: "not-a-date")
      assert event.timestamp == nil
      refute WorkerEvent.activity?(event)
      assert WorkerEvent.classify_activity_timestamp(nil, "not-a-date") == :invalid
    end
  end

  describe "to_update/1" do
    test "formats worker event into update channel payload with tokenUsage compatibility" do
      event =
        WorkerEvent.new(
          event: :step_finish,
          session_id: "ses-up-1",
          harness: :opencode,
          timestamp: ~U[2026-10-09 18:30:00Z],
          usage: %{input_tokens: 100, output_tokens: 200, total_tokens: 300}
        )

      update = WorkerEvent.to_update(event)

      assert update.event == :step_finish
      assert %DateTime{} = update.timestamp
      assert update.session_id == "ses-up-1"
      assert update.usage == %{input_tokens: 100, output_tokens: 200, total_tokens: 300}

      assert update.tokenUsage.total == %{
               inputTokens: 100,
               outputTokens: 200,
               totalTokens: 300
             }

      assert update.terminal? == false
      assert update.harness == :opencode
    end
  end

  describe "callback/3 and AgentRunner.worker_event_callback/3" do
    test "WorkerEvent.callback dispatches normalized updates to recipient" do
      recipient = self()
      callback = WorkerEvent.callback(recipient, "ISS-500", channel: :codex_worker_update)

      raw_line = ~s({"type":"step_finish","sessionID":"s-500","part":{"tokens":{"input":10,"output":20}}})
      assert :ok = callback.(raw_line)

      assert_receive {:codex_worker_update, "ISS-500", update}
      assert update.event == :step_finish
      assert update.session_id == "s-500"
      assert update.usage.input_tokens == 10
      assert update.usage.output_tokens == 20
    end

    test "AgentRunner.worker_event_callback delegates to WorkerEvent contract" do
      recipient = self()
      callback = AgentRunner.worker_event_callback(recipient, %{id: "ISS-600"}, channel: :worker_update)

      raw_line = ~s({"type":"step_start","sessionID":"s-600"})
      assert :ok = callback.(raw_line)

      assert_receive {:worker_update, "ISS-600", update}
      assert update.event == :step_start
      assert update.session_id == "s-600"
    end
  end

  describe "Access behaviour" do
    test "supports map-like key access on WorkerEvent struct" do
      event = WorkerEvent.new(event: :step_start, session_id: "ses-acc")

      assert event[:event] == :step_start
      assert event[:session_id] == "ses-acc"
      assert event[:timestamp] == nil
      assert event["event"] == :step_start
      assert event["session_id"] == "ses-acc"
    end
  end

  describe "OpenCode step accounting, redaction, and callback identity" do
    test "two different steps with identical token counts both accumulate" do
      first = step_line("m-a", "stop", 40, 40)
      second = step_line("m-b", "stop", 40, 40)

      assert {:ok, state, event_a} = WorkerEvent.accumulate(nil, first)
      assert event_a.usage.input_tokens == 40
      assert event_a.usage.output_tokens == 40
      assert event_a.metadata.usage_accounting == :cumulative

      assert {:ok, _state, event_b} = WorkerEvent.accumulate(state, second)
      assert event_b.usage.input_tokens == 80
      assert event_b.usage.output_tokens == 80
      assert event_b.usage.total_tokens == 160
    end

    test "a repeated step identity is not counted twice" do
      line = step_line("m-same", "stop", 40, 40)
      assert {:ok, state, _} = WorkerEvent.accumulate(nil, line)
      assert {:duplicate, _state} = WorkerEvent.accumulate(state, line)
    end

    test "malformed JSON keeps no decoder data and no secret" do
      secret = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz"
      linear = "lin_api_parentsecretvalue"
      line = ~s({"type":"tool_use","broken":"#{secret}","token":"LINEAR_API_KEY=#{linear}")

      event = WorkerEvent.from_opencode(line)

      refute inspect(event) =~ secret
      refute inspect(event) =~ linear
      refute inspect(event) =~ "DecodeError"
      assert event.payload.error == :json_decode_error
      assert Map.keys(event.payload.detail) |> Enum.sort() == [:position, :token]
      assert event.timestamp == nil
      refute WorkerEvent.activity?(event)
    end

    test "tool output is redacted and bounded before it can reach a callback" do
      secret = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz"
      output = secret <> " " <> String.duplicate("x", 5_000)

      raw =
        Jason.encode!(%{
          "type" => "tool_use",
          "sessionID" => "ses-secret",
          "timestamp" => 1_728_490_000,
          "part" => %{
            "tool" => "bash",
            "callID" => "call-1",
            "messageID" => "m-tool",
            "state" => %{"status" => "completed", "output" => output}
          }
        })

      event = WorkerEvent.from_opencode(raw)
      assert event.payload.output =~ "[redacted]"
      refute event.payload.output =~ secret
      assert byte_size(event.payload.output) < 4_200
      refute inspect(event.raw) =~ secret

      smuggled = %{event | raw: secret}
      recipient = self()
      callback = WorkerEvent.callback(recipient, "ISS-701")
      assert :ok = callback.(smuggled)

      assert_receive {:codex_worker_update, "ISS-701", update}
      refute inspect(update) =~ secret
      assert update.successful_completion? == false
    end

    test "multibyte evidence is truncated on a codepoint boundary within the byte budget" do
      secret = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz"
      suffix = "…[truncated]"
      budget = 4_096 - byte_size(suffix)
      head = "[redacted] "
      pad = if rem(budget - byte_size(head), 3) == 0, do: "x", else: ""
      assert rem(budget - byte_size(head <> pad), 3) != 0

      output = secret <> " " <> pad <> String.duplicate("€", 2_000)

      event =
        WorkerEvent.from_opencode(%{
          "type" => "tool_use",
          "sessionID" => "ses-utf8",
          "timestamp" => 1_728_490_000,
          "part" => %{
            "tool" => "bash",
            "callID" => "call-utf8",
            "messageID" => "m-utf8",
            "state" => %{"status" => "completed", "output" => output}
          }
        })

      update = WorkerEvent.to_update(event)
      bounded = update.payload.output

      assert String.valid?(bounded)
      assert byte_size(bounded) <= 4_096
      assert String.ends_with?(bounded, "[truncated]")
      assert bounded =~ "€"
      refute bounded =~ secret
      refute bounded =~ "sk-ant"
      refute inspect(update) =~ secret
      assert is_binary(Jason.encode!(update))
    end

    test "truncation does not reintroduce a secret that straddles the byte budget" do
      secret = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz"
      suffix = "…[truncated]"
      budget = 4_096 - byte_size(suffix)
      fragment = binary_part(secret, 0, 8)
      assert fragment == "sk-ant-a"
      separator = " "
      lead = String.duplicate("a", budget - byte_size(fragment) - byte_size(separator))
      output = lead <> separator <> secret <> separator <> String.duplicate("€", 30)

      event =
        WorkerEvent.from_opencode(%{
          "type" => "tool_use",
          "sessionID" => "ses-boundary",
          "timestamp" => 1_728_490_000,
          "part" => %{
            "tool" => "bash",
            "callID" => "call-boundary",
            "messageID" => "m-boundary",
            "state" => %{"status" => "completed", "output" => output}
          }
        })

      update = WorkerEvent.to_update(event)
      bounded = update.payload.output

      assert String.valid?(bounded)
      assert byte_size(bounded) <= 4_096
      assert String.ends_with?(bounded, "[truncated]")
      refute bounded =~ secret
      refute bounded =~ "sk-ant"
      refute inspect(update.raw) =~ "sk-ant"
      assert is_binary(Jason.encode!(update))
    end

    test "callback delivers the final event and then stops its helper" do
      parent = self()
      issue_id = "ISS-FINAL-800"

      recipient =
        spawn(fn ->
          receive do
            {:codex_worker_update, ^issue_id, update} ->
              send(parent, {:delivered, update})

              receive do
                :stop -> :ok
              after
                5_000 -> :ok
              end
          after
            5_000 -> :ok
          end
        end)

      callback = WorkerEvent.callback(recipient, issue_id)
      helper = callback_helper!(issue_id)
      assert Process.alive?(helper)

      assert :ok = callback.(step_line("m-final", "stop", 3, 4))
      assert_receive {:delivered, update}
      assert update.usage.input_tokens == 3
      assert Process.alive?(helper)

      send(recipient, :stop)
      refute alive_after?(helper)
      assert :ok = callback.(step_line("m-after", "stop", 1, 1))
      refute_receive {:delivered, _}, 50
      assert callback_helper(issue_id) == nil
    end

    test "callback helper exits when its creator exits" do
      parent = self()
      issue_id = "ISS-OWNER-801"

      recipient =
        spawn(fn ->
          receive do
            :stop -> :ok
          after
            5_000 -> :ok
          end
        end)

      creator =
        spawn(fn ->
          _callback = WorkerEvent.callback(recipient, issue_id)
          send(parent, :ready)

          receive do
            :stop -> :ok
          after
            5_000 -> :ok
          end
        end)

      on_exit(fn ->
        if Process.alive?(creator), do: Process.exit(creator, :kill)
        if Process.alive?(recipient), do: Process.exit(recipient, :kill)
      end)

      assert_receive :ready
      helper = callback_helper!(issue_id)
      assert Process.alive?(helper)

      Process.exit(creator, :kill)
      refute alive_after?(helper)
    end

    test "malformed issue ids, dead recipients, and session changes do not dispatch" do
      line = step_line("m-1", "tool-calls", 5, 5)

      assert :ok = WorkerEvent.callback(self(), "").(line)
      assert :ok = WorkerEvent.callback(self(), "bad id").(line)
      refute_receive {:codex_worker_update, _, _}, 50

      dead =
        spawn(fn ->
          :ok
        end)

      Process.sleep(20)
      assert :ok = WorkerEvent.callback(dead, "ISS-702").(line)
      refute_receive _, 50

      callback = WorkerEvent.callback(self(), "ISS-703")
      assert :ok = callback.(step_line("m-1", "tool-calls", 5, 5, "ses-a"))
      assert_receive {:codex_worker_update, "ISS-703", first}
      assert first.session_id == "ses-a"
      assert first.usage.input_tokens == 5

      assert :ok = callback.(step_line("m-2", "stop", 9, 9, "ses-b"))
      refute_receive {:codex_worker_update, "ISS-703", _}, 50

      assert :ok = callback.(step_line("m-3", "stop", 1, 1, "ses-a"))
      assert_receive {:codex_worker_update, "ISS-703", third}
      assert third.session_id == "ses-a"
      assert third.usage.input_tokens == 6
    end

    test "out-of-order timestamps are classified without moving the accepted clock backward" do
      newer = ~U[2026-10-09 18:31:00Z]
      older = ~U[2026-10-09 18:30:00Z]

      assert {:fresh, ^newer} = WorkerEvent.classify_activity_timestamp(nil, newer)
      assert :stale = WorkerEvent.classify_activity_timestamp(newer, older)
      assert {:fresh, ^newer} = WorkerEvent.classify_activity_timestamp(older, newer)
    end
  end

  defp step_finish(reason) do
    part = %{"messageID" => "msg-reason", "tokens" => %{"input" => 1, "output" => 1}}
    part = if is_binary(reason), do: Map.put(part, "reason", reason), else: part

    WorkerEvent.from_opencode(%{
      "type" => "step_finish",
      "timestamp" => 1_728_490_010,
      "sessionID" => "ses-reason",
      "part" => part
    })
  end

  defp alive_after?(pid, attempts \\ 20)

  defp alive_after?(_pid, 0), do: true

  defp alive_after?(pid, attempts) do
    if Process.alive?(pid) do
      Process.sleep(10)
      alive_after?(pid, attempts - 1)
    else
      false
    end
  end

  defp callback_helper!(issue_id) do
    pid = callback_helper(issue_id, 20)
    assert is_pid(pid)
    pid
  end

  defp callback_helper(issue_id, attempts \\ 1)

  defp callback_helper(_issue_id, 0), do: nil

  defp callback_helper(issue_id, attempts) do
    case Enum.find(Process.list(), &callback_helper?(&1, issue_id)) do
      nil ->
        Process.sleep(10)
        callback_helper(issue_id, attempts - 1)

      pid ->
        pid
    end
  end

  defp callback_helper?(pid, issue_id) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} -> dict[:symphony_worker_event_callback] == issue_id
      _ -> false
    end
  end

  defp step_line(message_id, reason, input, output, session_id \\ "ses-acc") do
    Jason.encode!(%{
      "type" => "step_finish",
      "timestamp" => 1_728_490_010,
      "sessionID" => session_id,
      "part" => %{
        "id" => "part-" <> message_id,
        "messageID" => message_id,
        "reason" => reason,
        "tokens" => %{"input" => input, "output" => output}
      }
    })
  end
end
