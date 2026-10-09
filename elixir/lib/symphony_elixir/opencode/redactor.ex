defmodule SymphonyElixir.OpenCode.Redactor do
  @moduledoc """
  Redacts and bounds sensitive text before OpenCode output leaves the adapter.

  Tool output, parser evidence, callbacks, stderr and failure records pass
  through this boundary. Binaries are scrubbed, truncated, and scrubbed again
  so a secret split by the byte bound cannot survive as a partial token. Lists
  and plain maps are walked. Atoms, numbers and structs are left unchanged.
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
    |> scrub()
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

  defp bound(value) do
    value
    |> binary_part(0, @max_bytes)
    |> drop_partial_codepoint()
    |> Kernel.<>(@truncated)
  end

  # binary_part/3 can split a multi-byte codepoint at the bound. Drop the
  # dangling bytes so bounded evidence stays valid UTF-8.
  defp drop_partial_codepoint(binary) do
    size = byte_size(binary)

    if String.valid?(binary) or size == 0 do
      binary
    else
      dangling = count_dangling_bytes(binary, min(size, 4), 0)
      binary_part(binary, 0, size - dangling)
    end
  end

  defp count_dangling_bytes(_binary, 0, count), do: count

  defp count_dangling_bytes(binary, left, count) do
    size = byte_size(binary)
    <<byte>> = binary_part(binary, size - 1, 1)

    if byte >= 0x80 do
      count_dangling_bytes(binary_part(binary, 0, size - 1), left - 1, count + 1)
    else
      count
    end
  end
end
