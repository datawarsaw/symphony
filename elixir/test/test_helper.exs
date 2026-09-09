ExUnit.start()
Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/fake_ssh.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)

# Capture the configured test baseline before any test can change shared state.
SymphonyElixir.TestSupport.capture_baseline!()
