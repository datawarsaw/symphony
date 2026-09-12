defmodule SymphonyElixir.AppServerFailureInfoTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.AppServer

  test "atoms expose kind with no invented metadata" do
    assert AppServer.failure_info({:error, :turn_timeout}) == %{kind: :turn_timeout, message: "turn_timeout", http_status: nil, reset_after_ms: nil, raw: :turn_timeout}
    assert AppServer.failure_info(:response_timeout).kind == :response_timeout
    assert AppServer.failure_info(123) == %{kind: :unknown, message: "123", http_status: nil, reset_after_ms: nil, raw: 123}
  end

  test "binary reasons stay opaque" do
    assert AppServer.failure_info({:error, "boom"}) == %{kind: :unknown, message: "boom", http_status: nil, reset_after_ms: nil, raw: "boom"}
  end

  test "map payloads surface message, status, and reset only when provided" do
    info = AppServer.failure_info({:error, {:turn_failed, %{"message" => "slow down", "status" => 429}}})
    assert info.kind == :turn_failed
    assert info.message == "slow down"
    assert info.http_status == 429
    assert info.reset_after_ms == nil

    reset = AppServer.failure_info({:error, {:response_error, %{"error" => "nope", "reset_after_ms" => 4_000}}})
    assert reset.reset_after_ms == 4_000
    assert reset.message == inspect("nope")

    atom_keys = AppServer.failure_info({:error, {:turn_failed, %{message: "bad", status: 503, retry_after_ms: 100}}})
    assert atom_keys.message == "bad"
    assert atom_keys.http_status == 503
    assert atom_keys.reset_after_ms == 100
  end

  test "alternate status and reset key spellings" do
    assert AppServer.failure_info({:error, {:port_exit, 1}}).message == "1"
    assert AppServer.failure_info({:error, {:turn_failed, %{"http_status" => 502}}}).http_status == 502
    assert AppServer.failure_info({:error, {:turn_failed, %{"status" => 0}}}).http_status == nil
    assert AppServer.failure_info({:error, {:turn_failed, %{"status" => "high"}}}).http_status == nil
    assert AppServer.failure_info({:error, {:turn_failed, %{"reset_after_ms" => -5}}}).reset_after_ms == nil
    assert AppServer.failure_info({:error, {:turn_failed, %{"retry_after_ms" => "soon"}}}).reset_after_ms == nil
    assert AppServer.failure_info({:error, {:turn_failed, %{"other" => true}}}).message =~ "other"
  end
end
