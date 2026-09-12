ExUnit.start()
Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/fake_ssh.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)

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
