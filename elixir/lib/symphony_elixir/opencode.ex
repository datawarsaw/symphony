defmodule SymphonyElixir.OpenCode do
  @moduledoc """
  Top-level module for the bounded OpenCode worker adapter in Symphony.

  Exposes:
  - run/3: Execute an OpenCode worker non-interactively
  - start_session/3: Start a managed OpenCode session
  - stop_session/1: Stop an active session and verify containment termination
  - classify_failure/1: Map OpenCode failure to Symphony's FailureClass taxonomy
  """

  alias SymphonyElixir.OpenCode.{Adapter, Failure}

  defdelegate run(workspace, prompt, opts \\ []), to: Adapter
  defdelegate start_session(workspace, prompt, opts \\ []), to: Adapter
  defdelegate stop_session(session), to: Adapter

  defdelegate classify_failure(reason), to: Failure, as: :classify
  defdelegate failure_info(reason), to: Failure
end
