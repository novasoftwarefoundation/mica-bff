defmodule Mix.Tasks.Bff.Compat do
  @shortdoc "Fails on a breaking change against the last spec version"
  @moduledoc """
      mix bff.compat [--against TAG]

  Compares the block catalogue with the one at TAG, by default the last `v*` tag,
  and fails on a breaking change (`MicaBff.Compat`). Without a `v*` tag there is
  nothing to compare, so it passes. The old catalogue is read by running that tag
  in a temporary git worktree, so the tag doesn't need this task.
  """
  use Mix.Task

  @requirements ["compile"]

  @print_schema ~S|IO.puts("bff-schema:" <> Base.encode64(:erlang.term_to_binary(MicaBff.Blocks.__schema__())))|

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [against: :string])

    case opts[:against] || last_tag() do
      nil -> Mix.shell().info("no v* tag yet, nothing to compare")
      tag -> compare(tag)
    end
  end

  defp last_tag do
    case git(["describe", "--tags", "--abbrev=0", "--match", "v*"]) do
      {tag, 0} -> String.trim(tag)
      {_, _} -> no_tag()
    end
  end

  # Describe also fails outside a repository; that must not pass CI as "no tag yet".
  defp no_tag do
    case git(["rev-parse", "--git-dir"]) do
      {_, 0} -> nil
      {output, _} -> Mix.raise("git failed:\n#{output}")
    end
  end

  defp compare(tag) do
    tag
    |> catalogue_at()
    |> MicaBff.Compat.breaking_changes(MicaBff.Blocks.__schema__())
    |> report(tag)
  end

  defp report([], tag), do: Mix.shell().info("compatible with #{tag}")

  defp report(changes, tag) do
    Mix.raise("""
    breaking changes against #{tag}:
    #{Enum.map_join(changes, "\n", &"  #{&1}")}

    Deprecate a field first and remove it after the next tag; add new fields as optional.
    """)
  end

  defp catalogue_at(tag) do
    dir = Path.join(System.tmp_dir!(), "bff_compat_#{System.pid()}")

    try do
      add_worktree(dir, tag)
      read_catalogue(dir, tag)
    after
      git(["worktree", "remove", "--force", dir])
    end
  end

  defp add_worktree(dir, tag) do
    case git(["worktree", "add", "--detach", dir, tag]) do
      {_, 0} -> :ok
      {output, _} -> Mix.raise("could not check out #{tag}:\n#{output}")
    end
  end

  defp read_catalogue(dir, tag) do
    {output, status} =
      System.cmd("mix", ["run", "-e", @print_schema], cd: dir, stderr_to_stdout: true)

    case {status, Regex.run(~r/^bff-schema:(\S+)$/m, output)} do
      {0, [_, encoded]} -> decode(encoded)
      _ -> Mix.raise("could not read the catalogue at #{tag}:\n#{output}")
    end
  end

  # Not [:safe]: that rejects atoms this VM doesn't know, and the name of a removed
  # block or field is exactly that. The bytes come from the tag's code we just ran.
  defp decode(encoded) do
    encoded
    |> Base.decode64!()
    |> :erlang.binary_to_term()
  end

  defp git(args), do: System.cmd("git", args, stderr_to_stdout: true)
end
