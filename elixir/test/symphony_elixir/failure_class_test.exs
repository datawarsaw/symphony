defmodule SymphonyElixir.FailureClassTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.FailureClass
  alias SymphonyElixir.FailureClass.FailureError

  test "all/0 exposes exactly the ten canonical classes" do
    assert FailureClass.all() == [
             :provider_quota,
             :provider_rate_limit,
             :provider_outage,
             :model_unavailable,
             :auth_unavailable,
             :runtime_unavailable,
             :probe_environment_error,
             :probe_infrastructure_error,
             :transient_worker_failure,
             :persistent_worker_failure
           ]
  end

  test "to_name/from_name round-trip every canonical class" do
    expected = %{
      provider_quota: "PROVIDER_QUOTA",
      provider_rate_limit: "PROVIDER_RATE_LIMIT",
      provider_outage: "PROVIDER_OUTAGE",
      model_unavailable: "MODEL_UNAVAILABLE",
      auth_unavailable: "AUTH_UNAVAILABLE",
      runtime_unavailable: "RUNTIME_UNAVAILABLE",
      probe_environment_error: "PROBE_ENVIRONMENT_ERROR",
      probe_infrastructure_error: "PROBE_INFRASTRUCTURE_ERROR",
      transient_worker_failure: "TRANSIENT_WORKER_FAILURE",
      persistent_worker_failure: "PERSISTENT_WORKER_FAILURE"
    }

    for {class, name} <- expected do
      assert FailureClass.to_name(class) == name
      assert FailureClass.from_name(name) == {:ok, class}
    end

    assert FailureClass.to_name(:bogus) == "TRANSIENT_WORKER_FAILURE"
    assert FailureClass.from_name("NOPE") == :error
    assert FailureClass.from_name(:atom) == :error
  end

  test "normalize_class/1 funnels stray values to canonical classes" do
    assert FailureClass.normalize_class(:provider_quota) == :provider_quota
    assert FailureClass.normalize_class("PROVIDER_QUOTA") == :provider_quota
    assert FailureClass.normalize_class("NOPE") == :transient_worker_failure
    assert FailureClass.normalize_class(:quota) == :provider_quota
    assert FailureClass.normalize_class(:bogus_atom) == :transient_worker_failure
    assert FailureClass.normalize_class(42) == :transient_worker_failure
  end

  test "classification module stays free of retry policy decisions" do
    refute function_exported?(FailureClass, :stop_reason, 3)
    refute function_exported?(FailureClass, :backoff_delay, 3)
    refute function_exported?(FailureClass, :park_immediately?, 1)
    refute function_exported?(FailureClass, :update_history, 3)
  end

  test "reset_in_ms/1 only surfaces reliably provided timing" do
    assert FailureClass.reset_in_ms(%FailureError{reset_in_ms: 9_000}) == 9_000
    assert FailureClass.reset_in_ms(%FailureError{}) == nil
    assert FailureClass.reset_in_ms(%{failure_info: %{reset_after_ms: 5_000}}) == 5_000
    assert FailureClass.reset_in_ms(%{failure_info: %{}}) == nil
    assert FailureClass.reset_in_ms({%{reset_after_ms: 7_000}, []}) == 7_000
    assert FailureClass.reset_in_ms(%{"retry_after_ms" => 3_000}) == 3_000
    assert FailureClass.reset_in_ms(%{retry_after_ms: 2_000}) == 2_000
    assert FailureClass.reset_in_ms(%{"nonsense" => 1}) == nil
    assert FailureClass.reset_in_ms({:turn_timeout, %{}}) == nil
    assert FailureClass.reset_in_ms(:turn_timeout) == nil
    assert FailureClass.reset_in_ms(nil) == nil
  end

  test "classify/1 maps structured failures to all ten classes" do
    assert FailureClass.classify(%FailureError{failure_class: :model_unavailable}) == :model_unavailable
    assert FailureClass.classify({%FailureError{failure_class: :provider_quota}, []}) == :provider_quota
    assert FailureClass.classify({%RuntimeError{message: "service 503 unavailable"}, []}) == :provider_outage
    assert FailureClass.classify(%RuntimeError{message: "unauthorized access denied"}) == :auth_unavailable
    assert FailureClass.classify({%{failure_class: :auth_unavailable}, []}) == :auth_unavailable
    assert FailureClass.classify(:quota) == :provider_quota
    assert FailureClass.classify(:bogus_atom) == :transient_worker_failure
    assert FailureClass.classify({:port_exit, 1}) == :probe_infrastructure_error
    assert FailureClass.classify({:mystery_tag, "quota exceeded fast"}) == :provider_quota
    assert FailureClass.classify(42) == :transient_worker_failure
  end

  test "classify/1 matches provider strings for every class" do
    assert FailureClass.classify("usage limit exceeded") == :provider_quota
    assert FailureClass.classify("rate limit exceeded, slow down") == :provider_rate_limit
    assert FailureClass.classify("unauthorized: invalid api key") == :auth_unavailable
    assert FailureClass.classify("model_not_found: gpt-xyz") == :model_unavailable
    assert FailureClass.classify("service unavailable (503)") == :provider_outage
    assert FailureClass.classify("connection timeout") == :runtime_unavailable
    assert FailureClass.classify("workspace outside_workspace_root") == :probe_environment_error
    assert FailureClass.classify("port_exit (status 1)") == :probe_infrastructure_error
    assert FailureClass.classify("turn cancelled by user") == :persistent_worker_failure
    assert FailureClass.classify("something unexpected broke") == :transient_worker_failure
  end

  test "classify/1 reads structured code/status maps" do
    assert FailureClass.classify(%{failure_class: :auth_unavailable}) == :auth_unavailable
    assert FailureClass.classify(%{"failure_class" => "PROVIDER_QUOTA"}) == :provider_quota
    assert FailureClass.classify(%{code: "rate_limit_exceeded"}) == :provider_rate_limit
    assert FailureClass.classify(%{code: :quota}) == :provider_quota
    assert FailureClass.classify(%{code: 429}) == :provider_rate_limit
    assert FailureClass.classify(%{code: %{weird: true}}) == :transient_worker_failure
    assert FailureClass.classify(%{status: 401}) == :auth_unavailable
    assert FailureClass.classify(%{status: 500}) == :provider_outage
    assert FailureClass.classify(%{status: 418}) == :transient_worker_failure
    assert FailureClass.classify(%{status: "high"}) == :transient_worker_failure
    assert FailureClass.classify(%{reason: "connection reset by peer"}) == :runtime_unavailable
    assert FailureClass.classify(%{}) == :transient_worker_failure
  end

  test "FailureError builds a default message and honors explicit fields" do
    raised =
      try do
        raise FailureError, failure_class: :provider_quota, reason: :quota
      rescue
        e in FailureError -> e
      end

    assert raised.failure_class == :provider_quota
    assert raised.reason == :quota
    assert raised.reset_in_ms == nil
    assert raised.message =~ "provider_quota"
    assert Exception.message(raised) == raised.message
    explicit = FailureError.exception(message: "boom", failure_class: :auth_unavailable, reason: "nope")
    assert explicit.message == "boom"
    assert explicit.failure_class == :auth_unavailable
  end
end
