defmodule SymphonyElixir.WorkerEventTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.WorkerEvent

  describe "new/1 and defaults" do
    test "creates a worker event with expected defaults" do
      event = WorkerEvent.new()

      assert event.event == :activity
      assert event.harness == :generic
      assert %DateTime{} = event.timestamp
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

    test "normalizes session.status idle as terminal completion" do
      raw = ~s({
        "type": "session.status",
        "timestamp": 1728490010,
        "sessionID": "ses-opencode-1",
        "properties": {
          "status": {"type": "idle"}
        }
      })

      event = WorkerEvent.from_opencode(raw)

      assert event.event == :turn_completed
      assert event.terminal? == true
      assert WorkerEvent.terminal?(event)
      assert event.session_id == "ses-opencode-1"
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

    test "falls back safely for invalid timestamp" do
      assert %DateTime{} = WorkerEvent.normalize_timestamp(nil)
      assert %DateTime{} = WorkerEvent.normalize_timestamp("not-a-date")
    end
  end

  describe "to_update/1" do
    test "formats worker event into update channel payload with tokenUsage compatibility" do
      event =
        WorkerEvent.new(
          event: :step_finish,
          session_id: "ses-up-1",
          harness: :opencode,
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
      assert %DateTime{} = event[:timestamp]
      assert event["event"] == :step_start
      assert event["session_id"] == "ses-acc"
    end
  end
end
