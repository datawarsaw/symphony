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
  @max_processing_bytes 65_536
  @replacement "�"

  @patterns [
    ~r/(?i)authorization\s*:\s*bearer\s+\S+/,
    ~r/(?i)bearer\s+[A-Za-z0-9\-._~+\/=]{8,}/,
    ~r/(?i)(?:api[_-]?key|access[_-]?token|refresh[_-]?token|secret|password|credential|auth[_-]?token)\b\s*[=:]\s*["']?[^\s"',}]+/,
    ~r/sk-ant-[A-Za-z0-9_\-]{8,}\b/,
    ~r/sk-[A-Za-z0-9_\-]{8,}\b/,
    ~r/gh[pousr]_[A-Za-z0-9]{20,}\b/,
    ~r/xox[baprs]-[A-Za-z0-9\-]{10,}\b/,
    ~r/AKIA[0-9A-Z]{16}\b/,
    ~r/lin_api_[A-Za-z0-9_\-]{8,}\b/
  ]

  @doc "Recursively redacts secrets and bounds binaries."
  @spec redact(term()) :: term()
  def redact(value) when is_binary(value) do
    value
    |> pre_bound()
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

  defp pre_bound(value) when byte_size(value) > @max_processing_bytes do
    binary_part(value, 0, @max_processing_bytes)
  end

  defp pre_bound(value), do: value

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
  @doc false
  @spec ensure_valid_utf8(binary() | list()) :: binary()
  def ensure_valid_utf8(binary) when is_binary(binary) do
    if String.valid?(binary) do
      binary
    else
      binary |> sanitize_utf8([]) |> IO.iodata_to_binary()
    end
  end

  def ensure_valid_utf8(chardata) when is_list(chardata) do
    case :unicode.characters_to_binary(chardata, :utf8, :utf8) do
      valid when is_binary(valid) ->
        valid

      _ ->
        chardata |> sanitize_utf8([]) |> IO.iodata_to_binary()
    end
  end

  @doc false
  @spec sanitize_utf8(binary() | list(), list()) :: list()
  def sanitize_utf8(<<>>, acc), do: Enum.reverse(acc)
  def sanitize_utf8([], acc), do: Enum.reverse(acc)

  def sanitize_utf8(input, acc) do
    case :unicode.characters_to_binary(input, :utf8, :utf8) do
      valid when is_binary(valid) ->
        Enum.reverse([valid | acc])

      {:error, valid, rest} ->
        {replacements, next_input} = advance_invalid(rest)
        acc1 = [replacements, valid | acc]
        sanitize_utf8(next_input, acc1)

      {:incomplete, valid, rest} ->
        count = count_rest_bytes(rest)
        replacements = String.duplicate(@replacement, count)
        Enum.reverse([replacements, valid | acc])
    end
  end

  defp advance_invalid(binary) when is_binary(binary) do
    skip_invalid_binary(binary, [])
  end

  defp advance_invalid(list) when is_list(list) do
    skip_invalid_list(list, [])
  end

  defp skip_invalid_binary(<<>>, acc) do
    {Enum.reverse(acc), <<>>}
  end

  defp skip_invalid_binary(<<_char::utf8, _::binary>> = rest, acc) when acc != [] do
    {Enum.reverse(acc), rest}
  end

  defp skip_invalid_binary(<<_byte, rest::binary>>, acc) do
    skip_invalid_binary(rest, [@replacement | acc])
  end

  defp skip_invalid_list([], acc) do
    {Enum.reverse(acc), []}
  end

  defp skip_invalid_list([head | tail], acc) when is_list(head) do
    skip_invalid_list(head ++ tail, acc)
  end

  defp skip_invalid_list([<<>> | tail], acc) do
    skip_invalid_list(tail, acc)
  end

  defp skip_invalid_list([<<_char::utf8, _::binary>> = head | tail], acc) when acc != [] do
    {Enum.reverse(acc), [head | tail]}
  end

  defp skip_invalid_list([head | tail], acc) when is_binary(head) do
    case skip_invalid_binary(head, []) do
      {replacements, <<>>} ->
        skip_invalid_list(tail, Enum.reverse(replacements) ++ acc)

      {replacements, remaining_bin} ->
        {Enum.reverse(acc, replacements), [remaining_bin | tail]}
    end
  end

  defp skip_invalid_list([_head | tail], acc) do
    skip_invalid_list(tail, [@replacement | acc])
  end

  defp count_rest_bytes(binary) when is_binary(binary), do: byte_size(binary)

  defp count_rest_bytes(list) when is_list(list) do
    Enum.reduce(list, 0, fn
      item, sum when is_integer(item) -> sum + 1
      item, sum when is_binary(item) -> sum + byte_size(item)
      item, sum when is_list(item) -> sum + count_rest_bytes(item)
      _item, sum -> sum + 1
    end)
  end

  defp count_rest_bytes(_), do: 1
end
