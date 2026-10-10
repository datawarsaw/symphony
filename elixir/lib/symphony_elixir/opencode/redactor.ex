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
  @budget @max_bytes - byte_size(@truncated)

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
    |> ensure_valid_utf8()
    |> scrub()
    |> bound()
    |> scrub()
    |> ensure_within_budget()
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
    |> binary_part(0, @budget)
    |> drop_partial_codepoint()
    |> Kernel.<>(@truncated)
  end

  defp ensure_within_budget(value) when byte_size(value) <= @max_bytes, do: value
  defp ensure_within_budget(value), do: bound(value)

  # Ensures bounded binary ends at a complete UTF-8 codepoint boundary so
  # truncated evidence is valid UTF-8.
  defp drop_partial_codepoint(binary) do
    case :unicode.characters_to_binary(binary, :utf8, :utf8) do
      valid when is_binary(valid) ->
        valid

      {:incomplete, valid, _rest} ->
        valid

      {:error, valid, _rest} ->
        valid
    end
  end

  # Replaces malformed or non-UTF-8 byte sequences with the Unicode replacement
  # character so sanitized evidence is always valid UTF-8 and JSON-encodable.
  defp ensure_valid_utf8(binary) when is_binary(binary) do
    if String.valid?(binary) do
      binary
    else
      binary |> sanitize_utf8([]) |> IO.iodata_to_binary()
    end
  end

  defp sanitize_utf8(<<>>, acc), do: Enum.reverse(acc)

  defp sanitize_utf8(binary, acc) do
    case :unicode.characters_to_binary(binary, :utf8, :utf8) do
      valid when is_binary(valid) ->
        Enum.reverse([valid | acc])

      {:error, valid, <<_invalid, rest::binary>>} ->
        sanitize_utf8(rest, ["", valid | acc])

      {:error, valid, <<>>} ->
        Enum.reverse([valid | acc])

      {:incomplete, valid, rest} ->
        Enum.reverse([String.duplicate("", byte_size(rest)), valid | acc])
    end
  end
end
