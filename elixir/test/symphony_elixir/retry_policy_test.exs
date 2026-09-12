defmodule SymphonyElixir.RetryPolicyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.RetryPolicy

  defp evaluate(class, history, now_ms) do
    RetryPolicy.evaluate(%{failure_class: class, history: history, now_ms: now_ms})
  end

  test "eligible transient failure retries" do
    assert evaluate(:provider_outage, nil, 1_000) == {:retry, %{attempt_count: 1, identical_failure_count: 1, first_failure_at_ms: 1_000, last_failure_at_ms: 1_000, last_failure_class: :provider_outage}}
  end

  test "attempt 9 retries" do
    history = %{attempt_count: 8, identical_failure_count: 1, first_failure_at_ms: 0, last_failure_at_ms: 1_000, last_failure_class: :provider_outage}

    assert {:retry, updated} = evaluate(:provider_outage, history, 2_000)
    assert updated.attempt_count == 9
  end

  test "attempt 10 parks on max_attempts" do
    history = %{attempt_count: 9, identical_failure_count: 1, first_failure_at_ms: 0, last_failure_at_ms: 1_000, last_failure_class: :provider_outage}

    assert {:park, :max_attempts, updated} = evaluate(:provider_outage, history, 2_000)
    assert updated.attempt_count == 10
  end

  test "failure age below two hours retries" do
    history = %{attempt_count: 5, identical_failure_count: 1, first_failure_at_ms: 0, last_failure_at_ms: 7_100_000, last_failure_class: :provider_quota}

    assert {:retry, _updated} = evaluate(:provider_quota, history, 7_199_999)
  end

  test "failure age of two hours or more parks on max_age" do
    history = %{attempt_count: 5, identical_failure_count: 1, first_failure_at_ms: 0, last_failure_at_ms: 7_200_000, last_failure_class: :provider_quota}

    assert {:park, :max_age, _updated} = evaluate(:provider_quota, history, 7_200_001)
  end

  test "identical consecutive count of 2 retries" do
    history = %{attempt_count: 1, identical_failure_count: 1, first_failure_at_ms: 0, last_failure_at_ms: 1_000, last_failure_class: :runtime_unavailable}

    assert {:retry, updated} = evaluate(:runtime_unavailable, history, 2_000)
    assert updated.identical_failure_count == 2
  end

  test "identical consecutive count of 3 parks on max_identical" do
    history = %{attempt_count: 2, identical_failure_count: 2, first_failure_at_ms: 0, last_failure_at_ms: 1_000, last_failure_class: :runtime_unavailable}

    assert {:park, :max_identical, updated} = evaluate(:runtime_unavailable, history, 2_000)
    assert updated.identical_failure_count == 3
  end

  test "a different failure class restarts the identical streak" do
    history = %{attempt_count: 2, identical_failure_count: 2, first_failure_at_ms: 0, last_failure_at_ms: 1_000, last_failure_class: :runtime_unavailable}

    assert {:retry, updated} = evaluate(:provider_quota, history, 2_000)
    assert updated.identical_failure_count == 1
  end

  test "AUTH_UNAVAILABLE parks immediately on the first failure" do
    assert {:park, :auth_unavailable, updated} = evaluate(:auth_unavailable, nil, 1_000)
    assert updated.attempt_count == 1
    assert updated.last_failure_class == :auth_unavailable
  end

  test "AUTH_UNAVAILABLE parks immediately even with fresh envelope counters" do
    history = %{attempt_count: 0, identical_failure_count: 0, first_failure_at_ms: 1_000, last_failure_at_ms: 1_000, last_failure_class: :provider_quota}

    assert {:park, :auth_unavailable, _updated} = evaluate(:auth_unavailable, history, 1_001)
  end

  test "provider reset floor above the exponential delay wins" do
    assert RetryPolicy.backoff_delay(1, 300_000, 120_000) == 120_000
  end

  test "exponential delay above the provider reset floor wins" do
    assert RetryPolicy.backoff_delay(1, 300_000, 5_000) == 10_000
    assert RetryPolicy.backoff_delay(4, 300_000, 10_000) == 80_000
  end

  test "backoff respects the configured cap" do
    assert RetryPolicy.backoff_delay(20, 30_000) == 30_000
    assert RetryPolicy.backoff_delay(7, 300_000) == 300_000
  end

  test "backoff doubles from the ten second base and tolerates junk attempts" do
    assert RetryPolicy.retry_base_ms() == 10_000
    assert RetryPolicy.backoff_delay(1, 300_000) == 10_000
    assert RetryPolicy.backoff_delay(2, 300_000) == 20_000
    assert RetryPolicy.backoff_delay(3, 300_000) == 40_000
    assert RetryPolicy.backoff_delay(1, 300_000, nil) == 10_000
    assert RetryPolicy.backoff_delay(0, 300_000) == 10_000
    assert RetryPolicy.backoff_delay(-2, 300_000) == 10_000
    assert RetryPolicy.backoff_delay(nil, 300_000) == 10_000
  end

  test "failure policy never classifies raw errors" do
    # No classification entry point exists on the policy module.
    refute function_exported?(RetryPolicy, :classify, 1)

    # A raw error string is not a serialized class name: it must not be
    # sniffed into PROVIDER_RATE_LIMIT/AUTH_UNAVAILABLE and must not trip the
    # immediate-auth park rule; it only decodes to the transient class.
    assert {:retry, updated} = evaluate("rate limit exceeded, unauthorized 401", nil, 1_000)
    assert updated.last_failure_class == :transient_worker_failure

    assert {:retry, updated} = evaluate(%RuntimeError{message: "quota exceeded"}, nil, 1_000)
    assert updated.last_failure_class == :transient_worker_failure
  end

  test "envelope thresholds and park-immediately rule are the frozen policy" do
    assert RetryPolicy.max_attempts() == 10
    assert RetryPolicy.max_age_ms() == 7_200_000
    assert RetryPolicy.max_identical() == 3
    assert RetryPolicy.retry_base_ms() == 10_000
    assert RetryPolicy.park_immediately?(:auth_unavailable)
    refute RetryPolicy.park_immediately?(:provider_quota)
  end

  test "stop_reason/3 trips on attempts, age, or identical streak" do
    assert RetryPolicy.stop_reason(10, 0, 0) == {:stop, :max_attempts}
    assert RetryPolicy.stop_reason(11, 0, 0) == {:stop, :max_attempts}
    assert RetryPolicy.stop_reason(0, 7_200_000, 0) == {:stop, :max_age}
    assert RetryPolicy.stop_reason(0, 0, 3) == {:stop, :max_identical}
    assert RetryPolicy.stop_reason(9, 7_199_999, 2) == :ok
    assert RetryPolicy.stop_reason(nil, nil, nil) == :ok
    assert RetryPolicy.should_stop?(10, 0, 0)
    refute RetryPolicy.should_stop?(1, 0, 0)
  end

  test "update_history/3 tracks attempts and identical streaks" do
    first = RetryPolicy.update_history(nil, :provider_quota, 1_000)
    assert first == %{attempt_count: 1, identical_failure_count: 1, first_failure_at_ms: 1_000, last_failure_at_ms: 1_000, last_failure_class: :provider_quota}

    second = RetryPolicy.update_history(first, :provider_quota, 2_000)
    assert second.attempt_count == 2
    assert second.identical_failure_count == 2
    assert second.first_failure_at_ms == 1_000
    assert second.last_failure_at_ms == 2_000

    switched = RetryPolicy.update_history(second, :provider_outage, 3_000)
    assert switched.attempt_count == 3
    assert switched.identical_failure_count == 1

    assert RetryPolicy.update_history(:oops, :provider_quota, 5).attempt_count == 1
  end

  test "reset_identical/1 clears the streak after successful continuation" do
    assert RetryPolicy.reset_identical(%{attempt_count: 2, identical_failure_count: 2}) == %{attempt_count: 2, identical_failure_count: 0}
    assert RetryPolicy.reset_identical(nil) == %{identical_failure_count: 0}
  end

  test "evaluate/1 accepts serialized class names and shorthand atoms" do
    assert {:retry, updated} = evaluate("PROVIDER_QUOTA", nil, 1_000)
    assert updated.last_failure_class == :provider_quota

    assert {:retry, updated} = evaluate(:rate_limit, nil, 1_000)
    assert updated.last_failure_class == :provider_rate_limit
  end

  test "evaluate/1 is deterministic for identical inputs" do
    history = %{attempt_count: 3, identical_failure_count: 3, first_failure_at_ms: 0, last_failure_at_ms: 1_000, last_failure_class: :provider_outage}

    assert evaluate(:provider_outage, history, 2_000) == evaluate(:provider_outage, history, 2_000)
  end
end
