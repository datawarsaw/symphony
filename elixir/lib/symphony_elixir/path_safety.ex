defmodule SymphonyElixir.PathSafety do
  @moduledoc false

  # Maximum length of a single path component (255 UTF-16 code units on
  # Windows). POSIX filesystems already surface ENAMETOOLONG through lstat for
  # components longer than NAME_MAX, but Windows reports not-found for a
  # non-existent overlong name instead, so PathSafety checks the limit
  # explicitly there to fail deterministically for names a filesystem can
  # never create without weakening containment validation.
  @max_component_utf16_units 255

  @spec canonicalize(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def canonicalize(path) when is_binary(path) do
    expanded_path = Path.expand(path)
    {root, segments} = split_absolute_path(expanded_path)

    case resolve_segments(root, [], segments) do
      {:ok, canonical_path} ->
        {:ok, canonical_path}

      {:error, reason} ->
        {:error, {:path_canonicalize_failed, expanded_path, reason}}
    end
  end

  defp split_absolute_path(path) when is_binary(path) do
    [root | segments] = Path.split(path)
    {root, segments}
  end

  defp resolve_segments(root, resolved_segments, []), do: {:ok, join_path(root, resolved_segments)}

  defp resolve_segments(root, resolved_segments, [segment | rest]) do
    if overlong_component?(segment) do
      {:error, :enametoolong}
    else
      candidate_path = join_path(root, resolved_segments ++ [segment])

      case File.lstat(candidate_path) do
        {:ok, %File.Stat{type: :symlink}} ->
          with {:ok, target} <- :file.read_link_all(String.to_charlist(candidate_path)) do
            resolved_target = Path.expand(IO.chardata_to_string(target), join_path(root, resolved_segments))
            {target_root, target_segments} = split_absolute_path(resolved_target)
            resolve_segments(target_root, [], target_segments ++ rest)
          end

        {:ok, _stat} ->
          resolve_segments(root, resolved_segments ++ [segment], rest)

        {:error, :enoent} ->
          {:ok, join_path(root, resolved_segments ++ [segment | rest])}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp overlong_component?(segment) do
    case :os.type() do
      {:win32, _} -> utf16_code_units(segment) > @max_component_utf16_units
      _ -> false
    end
  end

  defp utf16_code_units(segment) do
    segment
    |> String.to_charlist()
    |> Enum.reduce(0, fn codepoint, acc ->
      if codepoint > 0xFFFF, do: acc + 2, else: acc + 1
    end)
  end

  defp join_path(root, segments) when is_list(segments) do
    Enum.reduce(segments, root, fn segment, acc -> Path.join(acc, segment) end)
  end
end
