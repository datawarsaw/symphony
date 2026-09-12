defmodule SymphonyElixir.FallbackPolicyTest do
  # MIC-195 Slice C: pure fallback route policy — eligibility classes,
  # thresholds, the consecutive eligible-primary fold, the route latch, and
  # the pin/opt-in permission rule. No config, no I/O, no Orchestrator state.
  use ExUnit.Case, async: true

  alias SymphonyElixir.RetryPolicy

  defp gates(opts) do
    Keyword.merge([fallback_available: true], opts)
  end

  # Fold one classified failure into the route state, then decide the route of
  # the next attempt — the exact sequence the Orchestrator performs.
  defp fold_and_decide(route_state, class, opts \\ []) do
    folded = RetryPolicy.update_route_state(route_state, class)
    RetryPolicy.fallback_route_decision(folded, class, gates(opts))
  end

  describe "fallback eligibility classes" do
    test "exactly the four approved classes are eligible" do
      assert RetryPolicy.fallback_eligible_classes() == [
               :model_unavailable,
               :provider_quota,
               :provider_rate_limit,
               :provider_outage
             ]
    end

    test "each eligible class switches exactly at its own threshold" do
      for class <- [:model_unavailable, :provider_quota, :provider_rate_limit, :provider_outage] do
        threshold = RetryPolicy.fallback_threshold(class)

        route_state =
          Enum.reduce(1..threshold, RetryPolicy.new_route_state(), fn n, acc ->
            {decision, updated} = fold_and_decide(acc, class)

            if n < threshold do
              assert {:stay_primary, _} = {decision, updated}
            end

            updated
          end)

        assert %{route: :fallback, primary_failure_count: ^threshold} = route_state
      end
    end
  end

  describe "thresholds" do
    test "MODEL_UNAVAILABLE falls back after 1 eligible primary failure" do
      assert RetryPolicy.fallback_threshold(:model_unavailable) == 1

      {decision, route_state} = fold_and_decide(RetryPolicy.new_route_state(), :model_unavailable)
      assert {:switch_to_fallback, %{route: :fallback, primary_failure_count: 1}} = {decision, route_state}
    end

    test "PROVIDER_QUOTA stays primary after failure #1 and falls back after failure #2" do
      assert RetryPolicy.fallback_threshold(:provider_quota) == 2

      {first, route_state} = fold_and_decide(RetryPolicy.new_route_state(), :provider_quota)
      assert {:stay_primary, %{route: :primary, primary_failure_count: 1}} = {first, route_state}

      {second, route_state} = fold_and_decide(route_state, :provider_quota)
      assert {:switch_to_fallback, %{route: :fallback, primary_failure_count: 2}} = {second, route_state}
    end

    test "PROVIDER_RATE_LIMIT stays primary after failure #1 and falls back after failure #2" do
      assert RetryPolicy.fallback_threshold(:provider_rate_limit) == 2

      {first, route_state} = fold_and_decide(RetryPolicy.new_route_state(), :provider_rate_limit)
      assert {:stay_primary, %{primary_failure_count: 1}} = {first, route_state}

      {second, route_state} = fold_and_decide(route_state, :provider_rate_limit)
      assert {:switch_to_fallback, %{route: :fallback, primary_failure_count: 2}} = {second, route_state}
    end

    test "PROVIDER_OUTAGE stays primary after failure #1 and falls back after failure #2" do
      assert RetryPolicy.fallback_threshold(:provider_outage) == 2

      {first, route_state} = fold_and_decide(RetryPolicy.new_route_state(), :provider_outage)
      assert {:stay_primary, %{primary_failure_count: 1}} = {first, route_state}

      {second, route_state} = fold_and_decide(route_state, :provider_outage)
      assert {:switch_to_fallback, %{route: :fallback, primary_failure_count: 2}} = {second, route_state}
    end

    test "ineligible classes have no threshold" do
      ineligible = [
        :auth_unavailable,
        :runtime_unavailable,
        :probe_environment_error,
        :probe_infrastructure_error,
        :transient_worker_failure,
        :persistent_worker_failure
      ]

      for class <- ineligible do
        assert RetryPolicy.fallback_threshold(class) == nil
        refute RetryPolicy.fallback_eligible_class?(class)
      end
    end
  end

  describe "ineligible classes never fall back" do
    test "AUTH_UNAVAILABLE never falls back even after repeated failures" do
      route_state = RetryPolicy.new_route_state()

      {decision, route_state} = fold_and_decide(route_state, :auth_unavailable)
      assert {:stay_primary, %{primary_failure_count: 0}} = {decision, route_state}

      {decision, route_state} = fold_and_decide(route_state, :auth_unavailable)
      assert {:stay_primary, %{primary_failure_count: 0}} = {decision, route_state}
    end

    test "RUNTIME_UNAVAILABLE never falls back" do
      {decision, route_state} = fold_and_decide(RetryPolicy.new_route_state(), :runtime_unavailable)
      assert {:stay_primary, %{primary_failure_count: 0}} = {decision, route_state}
    end

    test "probe classes never fall back" do
      for class <- [:probe_environment_error, :probe_infrastructure_error] do
        {decision, route_state} = fold_and_decide(RetryPolicy.new_route_state(), class)
        assert {:stay_primary, %{primary_failure_count: 0}} = {decision, route_state}
      end
    end

    test "worker failure classes never fall back" do
      for class <- [:transient_worker_failure, :persistent_worker_failure] do
        {decision, route_state} = fold_and_decide(RetryPolicy.new_route_state(), class)
        assert {:stay_primary, %{primary_failure_count: 0}} = {decision, route_state}
      end
    end

    test "an ineligible failure breaks the consecutive eligible-primary sequence" do
      # quota #1 reaches count 1, then an ineligible failure resets to 0, and a
      # single subsequent quota failure is only count 1 — below threshold 2.
      {_, route_state} = fold_and_decide(RetryPolicy.new_route_state(), :provider_quota)
      assert %{primary_failure_count: 1} = route_state

      {_, route_state} = fold_and_decide(route_state, :runtime_unavailable)
      assert %{primary_failure_count: 0} = route_state

      {decision, route_state} = fold_and_decide(route_state, :provider_quota)
      assert {:stay_primary, %{primary_failure_count: 1}} = {decision, route_state}
    end
  end

  describe "route latch" do
    test "fallback failures do not increment primary_failure_count" do
      latched = %{route: :fallback, primary_failure_count: 2}

      for class <- [:provider_quota, :model_unavailable, :runtime_unavailable] do
        assert RetryPolicy.update_route_state(latched, class) == latched
      end
    end

    test "the latch prevents fallback→primary transitions even after ineligible failures" do
      latched = %{route: :fallback, primary_failure_count: 2}

      {decision, route_state} = fold_and_decide(latched, :provider_quota)
      assert {:stay_fallback, %{route: :fallback}} = {decision, route_state}

      {decision, route_state} = fold_and_decide(route_state, :transient_worker_failure)
      assert {:stay_fallback, %{route: :fallback}} = {decision, route_state}
    end

    test "the latched route ignores pin and availability gates entirely" do
      latched = %{route: :fallback, primary_failure_count: 2}

      {decision, route_state} =
        RetryPolicy.fallback_route_decision(latched, :provider_quota,
          fallback_available: false,
          pinned: true,
          fallback_opt_in: :none
        )

      assert {:stay_fallback, %{route: :fallback}} = {decision, route_state}
    end
  end

  describe "gate: fallback availability" do
    test "threshold reached but fallback unavailable stays primary" do
      {decision, route_state} =
        fold_and_decide(RetryPolicy.new_route_state(), :model_unavailable, fallback_available: false)

      assert {:stay_primary, %{route: :primary, primary_failure_count: 1}} = {decision, route_state}
    end
  end

  describe "pin policy" do
    test "explicit pin blocks fallback without opt-in" do
      {decision, route_state} = fold_and_decide(RetryPolicy.new_route_state(), :model_unavailable, pinned: true)

      assert {:stay_primary, %{route: :primary, primary_failure_count: 1}} = {decision, route_state}
    end

    test "explicit pin with explicit fallback opt-in permits threshold-based fallback" do
      {decision, route_state} =
        fold_and_decide(RetryPolicy.new_route_state(), :model_unavailable, pinned: true, fallback_opt_in: :opt_in)

      assert {:switch_to_fallback, %{route: :fallback}} = {decision, route_state}
    end

    test "explicit opt-out blocks fallback even when unpinned" do
      {decision, route_state} =
        fold_and_decide(RetryPolicy.new_route_state(), :model_unavailable, pinned: false, fallback_opt_in: :opt_out)

      assert {:stay_primary, _} = {decision, route_state}
    end

    test "ambiguous opt-in fails closed even when unpinned" do
      {decision, route_state} =
        fold_and_decide(RetryPolicy.new_route_state(), :model_unavailable, pinned: false, fallback_opt_in: :ambiguous)

      assert {:stay_primary, _} = {decision, route_state}
    end

    test "unpinned issues fall back without any opt-in" do
      {decision, route_state} =
        fold_and_decide(RetryPolicy.new_route_state(), :model_unavailable, pinned: false, fallback_opt_in: :none)

      assert {:switch_to_fallback, _} = {decision, route_state}
    end

    test "pinned provider-quota sequence still requires two consecutive failures with opt-in" do
      {first, route_state} =
        fold_and_decide(RetryPolicy.new_route_state(), :provider_quota, pinned: true, fallback_opt_in: :opt_in)

      assert {:stay_primary, %{primary_failure_count: 1}} = {first, route_state}

      {second, route_state} = fold_and_decide(route_state, :provider_quota, pinned: true, fallback_opt_in: :opt_in)
      assert {:switch_to_fallback, %{primary_failure_count: 2}} = {second, route_state}
    end
  end

  describe "fallback_opt_in/1 label parsing" do
    test "no fallback label is :none" do
      assert RetryPolicy.fallback_opt_in([]) == :none
      assert RetryPolicy.fallback_opt_in(["backend", "model:gpt-5.6-sol"]) == :none
      assert RetryPolicy.fallback_opt_in(["fallback"]) == :none
      assert RetryPolicy.fallback_opt_in(nil) == :none
    end

    test "fallback:true opts in, case-insensitively" do
      assert RetryPolicy.fallback_opt_in(["fallback:true"]) == :opt_in
      assert RetryPolicy.fallback_opt_in(["Fallback:TRUE"]) == :opt_in
      assert RetryPolicy.fallback_opt_in([" fallback: true "]) == :opt_in
    end

    test "fallback:false opts out" do
      assert RetryPolicy.fallback_opt_in(["fallback:false"]) == :opt_out
      assert RetryPolicy.fallback_opt_in(["FALLBACK:False"]) == :opt_out
    end

    test "any other value is ambiguous" do
      assert RetryPolicy.fallback_opt_in(["fallback:maybe"]) == :ambiguous
      assert RetryPolicy.fallback_opt_in(["fallback:1"]) == :ambiguous
      assert RetryPolicy.fallback_opt_in(["fallback:"]) == :ambiguous
    end

    test "more than one fallback label is ambiguous" do
      assert RetryPolicy.fallback_opt_in(["fallback:true", "fallback:false"]) == :ambiguous
    end
  end

  describe "route fold keeps the envelope authoritative" do
    test "update_route_state/2 never touches envelope history fields" do
      route_state = %{route: :primary, primary_failure_count: 0, attempt_count: 7, identical_failure_count: 3, first_failure_at_ms: 1}

      folded = RetryPolicy.update_route_state(route_state, :model_unavailable)

      assert folded.attempt_count == 7
      assert folded.identical_failure_count == 3
      assert folded.first_failure_at_ms == 1
      assert folded.primary_failure_count == 1
    end

    test "legacy route maps without a route key fold as primary" do
      assert RetryPolicy.update_route_state(%{}, :model_unavailable) == %{route: :primary, primary_failure_count: 1}
      assert RetryPolicy.update_route_state(nil, :provider_quota) == %{route: :primary, primary_failure_count: 1}
    end
  end
end
