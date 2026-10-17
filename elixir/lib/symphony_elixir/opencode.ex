defmodule SymphonyElixir.OpenCode do
  @moduledoc """
  Top-level module for the bounded OpenCode worker adapter in Symphony.

  Exposes:
  - run/3: Execute an OpenCode worker non-interactively
  - start_session/3: Start a managed OpenCode session
  - stop_session/1: Stop an active session and verify containment termination
  - classify_failure/1: Map OpenCode failure to Symphony's FailureClass taxonomy
  - preflight_provider_credentials/2: presence-only credential availability
    check (the same check the adapter runs before any launch artifact exists)
  """

  alias SymphonyElixir.OpenCode.{Adapter, Environment, Failure}

  defdelegate run(workspace, prompt, opts \\ []), to: Adapter
  defdelegate start_session(workspace, prompt, opts \\ []), to: Adapter
  defdelegate stop_session(session), to: Adapter

  defdelegate preflight_provider_credentials(provider, opts \\ []), to: Environment

  defdelegate classify_failure(reason), to: Failure, as: :classify
  defdelegate failure_info(reason), to: Failure
end
