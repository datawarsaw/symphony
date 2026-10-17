defmodule SymphonyElixir.OpenCodeFailureTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{FailureClass, RetryPolicy}
  alias SymphonyElixir.OpenCode.{Failure, Parser}

  # Schema-derived, nonsecret fixtures (not captured provider traffic):
  # anomalyco/opencode v1.18.28 packages/schema/src/v1/session.ts.
  defp api(data), do: %{"name" => "APIError", "data" => Map.put(data, "message", "provider refused")}

  test "real APIError HTTP matrix, independent of misleading text" do
    for retryable <- [true, false], status <- [401, 403, 404, 429, 500, 501, 502, 503, 504, 599] do
      expected =
        cond do
          status == 401 -> :auth_unavailable
          status in [403, 404] or not retryable -> :persistent_worker_failure
          status == 429 -> :provider_rate_limit
          true -> :provider_outage
        end

      error = api(%{"statusCode" => status, "isRetryable" => retryable})
      assert Failure.classify(error) == expected
      assert Failure.classify({:error_event, error}) == expected
      assert FailureClass.classify(Failure.failure_info(error)) == expected
      assert Failure.classify(put_in(error, ["data", "message"], "quota rate limit timeout model not found")) == expected
    end
  end

  test "absent, malformed and unsupported status or retry flag fail closed" do
    for data <- [
          %{},
          %{"isRetryable" => true},
          %{"statusCode" => 429},
          %{"statusCode" => 503},
          %{"statusCode" => 503, "isRetryable" => nil},
          %{"statusCode" => 503, "isRetryable" => "true"},
          %{"statusCode" => 503, "isRetryable" => 1},
          %{"statusCode" => nil, "isRetryable" => true},
          %{"statusCode" => "429", "isRetryable" => true},
          %{"statusCode" => 503.0, "isRetryable" => true},
          %{"statusCode" => %{}, "isRetryable" => true},
          %{"statusCode" => false, "isRetryable" => true},
          %{"statusCode" => 0, "isRetryable" => true},
          %{"statusCode" => 200, "isRetryable" => true},
          %{"statusCode" => 400, "isRetryable" => true},
          %{"statusCode" => 600, "isRetryable" => true}
        ] do
      assert Failure.classify(api(data)) == :persistent_worker_failure
    end

    for data <- [nil, false, 123, "invalid", []] do
      error = %{"name" => "APIError", "data" => data}
      assert Failure.classify(error) == :persistent_worker_failure
      assert Failure.failure_info(error).failure_class == :persistent_worker_failure
      assert Failure.classify(Map.put(error, "status", 429)) == :persistent_worker_failure
    end
  end

  test "conflicting aliases fail closed while authentication evidence still parks immediately" do
    base = api(%{"statusCode" => 503, "isRetryable" => true})

    for error <- [
          Map.put(base, "status", 429),
          Map.put(base, "statusCode", 502),
          Map.put(base, "statusCode", nil),
          Map.put(base, "isRetryable", false),
          put_in(base, ["data", :statusCode], 429),
          put_in(base, ["data", :isRetryable], false)
        ] do
      assert Failure.classify(error) == :persistent_worker_failure
    end

    assert Failure.classify(Map.put(base, "status", 401)) == :auth_unavailable
    assert Failure.classify(Map.put(base, "status", 403)) == :persistent_worker_failure
    assert Failure.classify(Map.put(base, "status", 503)) == :provider_outage
    assert Failure.classify(Map.put(base, "isRetryable", true)) == :provider_outage
    assert Failure.classify(%{"name" => "APIError", "status" => 429, "data" => %{"status" => 503}}) == :persistent_worker_failure
  end

  test "malformed legacy status and conflicting error containers cannot enable fallback" do
    for status <- [nil, false, "429", 429.0, [], %{}, 0, 600] do
      error = %{"name" => "APIError", "status" => status, "data" => %{"message" => "rate limit"}}
      assert Failure.classify(error) == :persistent_worker_failure
    end

    base = api(%{"statusCode" => 503, "isRetryable" => true})
    assert Failure.classify(Map.put(base, :data, %{"statusCode" => 429, "isRetryable" => false})) == :persistent_worker_failure
    assert Failure.classify(Map.put(base, :data, nil)) == :persistent_worker_failure
    assert Failure.classify(Map.put(base, :data, base["data"])) == :provider_outage
    assert Failure.classify(Map.put(base, :name, "UnknownError")) == :persistent_worker_failure
    assert Failure.classify(Map.put(base, :name, "APIError")) == :provider_outage
  end

  test "atom keys and top-level metadata are supported without boolean coercion" do
    assert Failure.classify(%{name: "APIError", data: %{statusCode: 429, isRetryable: true}}) == :provider_rate_limit
    assert Failure.classify(%{statusCode: 503, isRetryable: true}) == :provider_outage
    assert Failure.classify(%{"statusCode" => 503, "isRetryable" => false}) == :persistent_worker_failure
  end

  test "unknown and aborted errors cannot infer provider retries from text or extra metadata" do
    for name <- ["UnknownError", "MessageAbortedError"],
        data <- [
          %{"message" => "rate limit quota model not found timeout"},
          %{"message" => "provider refused", "ref" => "nonsecret-reference"},
          %{"statusCode" => 429, "isRetryable" => true},
          %{"statusCode" => 401, "isRetryable" => true}
        ] do
      assert Failure.classify(%{"name" => name, "data" => data}) == :persistent_worker_failure
    end

    assert Failure.classify(%{"name" => "ProviderAuthError", "data" => %{"providerID" => "fixture", "message" => "failed"}}) ==
             :auth_unavailable
  end

  test "legacy HTTP and named/text classifications remain supported" do
    for {status, expected} <- [
          {401, :auth_unavailable},
          {403, :persistent_worker_failure},
          {429, :provider_rate_limit},
          {500, :provider_outage},
          {502, :provider_outage},
          {503, :provider_outage},
          {504, :provider_outage},
          {404, :transient_worker_failure},
          {501, :transient_worker_failure}
        ] do
      for error <- [%{"status" => status}, %{status: status}, %{"data" => %{"status" => status}}] do
        assert Failure.classify(error) == expected
        assert Failure.classify(Map.put(error, "name", "APIError")) == expected
      end
    end

    for {name, expected} <- [
          {"AuthError", :auth_unavailable},
          {"UnauthorizedError", :auth_unavailable},
          {"ModelNotFoundError", :model_unavailable},
          {"RateLimitError", :provider_rate_limit},
          {"QuotaExceededError", :provider_quota},
          {"ServerError", :provider_outage},
          {"TimeoutError", :runtime_unavailable}
        ] do
      assert Failure.classify(%{"name" => name, "data" => %{"message" => "provider refused"}}) == expected
    end

    assert Failure.classify("unauthorized") == :auth_unavailable
    assert Failure.classify(%{"data" => %{"message" => "rate limit"}}) == :provider_rate_limit
  end

  test "schema fixtures cross the JSONL parser into canonical failure info" do
    for error <- [
          api(%{"statusCode" => 401, "isRetryable" => false}),
          api(%{"statusCode" => 429, "isRetryable" => true}),
          %{"name" => "UnknownError", "data" => %{"message" => "unknown", "ref" => "fixture"}},
          %{"name" => "MessageAbortedError", "data" => %{"message" => "aborted"}}
        ] do
      line = Jason.encode!(%{"type" => "error", "timestamp" => 1, "sessionID" => "ses_fixture", "error" => error}) <> "\n"
      result = Parser.new() |> Parser.feed(line) |> Parser.finish(1) |> Parser.to_result()
      assert result.completion_state == :failed
      assert [{:error_event, parsed_error}, {:process_exit, 1}] = result.failure_evidence
      assert Failure.failure_info(parsed_error).failure_class == Failure.classify(error)
    end
  end

  test "auth parks immediately; authorization, unknown and non-retryable failures stay bounded without fallback" do
    auth_class = Failure.classify(api(%{"statusCode" => 401, "isRetryable" => true}))
    assert {:park, :auth_unavailable, _} = RetryPolicy.evaluate(%{failure_class: auth_class, now_ms: 0})

    for error <- [api(%{"statusCode" => 403, "isRetryable" => true}), api(%{"statusCode" => 503, "isRetryable" => false}), %{"name" => "UnknownError", "data" => %{"message" => "rate limit"}}] do
      class = Failure.classify(error)
      refute RetryPolicy.fallback_eligible_class?(class)
      assert {:retry, first} = RetryPolicy.evaluate(%{failure_class: class, now_ms: 0})
      assert {:retry, second} = RetryPolicy.evaluate(%{failure_class: class, history: first, now_ms: 1})
      assert {:park, :max_identical, _} = RetryPolicy.evaluate(%{failure_class: class, history: second, now_ms: 2})
    end
  end
end
