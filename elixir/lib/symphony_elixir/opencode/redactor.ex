defmodule SymphonyElixir.OpenCode.Redactor do
  @moduledoc """
  Redacts and bounds sensitive text before OpenCode output leaves the adapter.

  Tool output, parser evidence, callbacks, stderr and failure records pass
  through this boundary. Binaries are scrubbed and truncated. Lists and plain
  maps are walked. Atoms, numbers and structs are left unchanged.
  """

  @max_bytes 4_096
  @truncated "…[truncated]"
  @redacted "[redacted]"

  @patterns [
    ~r/(?i)\bauthorization\s*:\s*bearer\s+\S+/,
    ~r/(?i)\bbearer\s+[A-Za-z0-9\-._~+\/=]{8,}/,
    ~r/(?i)\b(?:api[_-]?key|access[_-]?token|refresh[_-]?token|secret|password|credential|auth[_-]?token)\b\s*[=:]\s*["']?[^\s"',}]+/,
    ~r/\bsk-ant-[A-Za-z0-9_\-]{8,}\b/,
    ~r/\bsk-[A-Za-z0-9_\-]{8,}\b/,
    ~r/\bgh[pousr]_[A-Za-z0-9]{20,}\b/,
    ~r/\bxox[baprs]-[A-Za-z0-9\-]{10,}\b/,
    ~r/\bAKIA[0-9A-Z]{16}\b/,
    ~r/\blin_api_[A-Za-z0-9_\-]{8,}\b/
  ]

  @doc "Recursively redacts secrets and bounds binaries."
  @spec redact(term()) :: term()
  def redact(value) when is_binary(value) do
    value
    |> scrub()
    |> bound()
  end

  def redact(value) when is_list(value), do: Enum.map(value, &redact/1)

  def redact(%{__struct__: _} = value), do: value

  def redact(value) when is_map(value) do
    Map.new(value, fn {key, inner} -> {key, redact(inner)} end)
  end

  def redact(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> redact()
    |> List.to_tuple()
  end

  def redact(value), do: value

  defp scrub(value) do
    Enum.reduce(@patterns, value, fn pattern, acc ->
      Regex.replace(pattern, acc, @redacted)
    end)
  end

  defp bound(value) when byte_size(value) <= @max_bytes, do: value

  defp bound(value), do: binary_part(value, 0, @max_bytes) <> @truncated
end
