ExUnit.start()
Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/fake_ssh.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)
Code.require_file("support/scratch_process.exs", __DIR__)
Code.require_file("support/delivery_fixtures.exs", __DIR__)

# MIC-223: on Windows the containment helper must exist and hash-verify before
# the suite runs, because local worker launches go through jobrun. Building from
# checked-in source is deterministic (in-box csc.exe) and fails visibly here.
case :os.type() do
  {:win32, _} ->
    case SymphonyElixir.WorkerContainment.ensure_helper_built() do
      :ok -> :ok
      {:error, reason} -> raise "MIC-223 jobrun helper build failed: #{inspect(reason)}"
    end

    SymphonyElixir.TestSupport.ScratchProcess.ensure_built!()

  _ ->
    :ok
end

# Capture the configured test baseline before any test can change shared state.
SymphonyElixir.TestSupport.capture_baseline!()

# Bounded cleanup for the per-run retry store root configured in config/config.exs
# for the test environment; it only ever holds records written outside a test's
# own per-test root and is removed with the rest of the run's fixtures.
ExUnit.after_suite(fn _stats ->
  case Application.get_env(:symphony_elixir, :retry_store_root) do
    root when is_binary(root) -> File.rm_rf(root)
    _other -> :ok
  end
end)
