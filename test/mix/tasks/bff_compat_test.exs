defmodule Mix.Tasks.Bff.CompatTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  unless System.find_executable("git"), do: @moduletag(skip: "needs git")

  @catalogue_with_gone_field """
  defmodule MicaBff.Blocks do
    use MicaBff.Schema

    defblock :section do
      field(:title, :string)
      field(:gone_with_the_tag, :string)
    end
  end
  """

  @catalogue_with_deprecated_field """
  defmodule MicaBff.Blocks do
    use MicaBff.Schema

    defblock :section do
      field(:title, :string)
      field(:gone_with_the_tag, :string, deprecated: "0.1.0")
    end
  end
  """

  @catalogue_without_field """
  defmodule MicaBff.Blocks do
    use MicaBff.Schema

    defblock :section do
      field(:title, :string)
    end
  end
  """

  test "a field removed since the tag fails, naming the field", %{tmp_dir: dir} do
    init_project(dir, @catalogue_with_gone_field)
    tag(dir, "v0.1.0")
    commit_catalogue(dir, @catalogue_without_field)

    {output, status} = compat(dir)

    assert status != 0
    assert output =~ "breaking changes against v0.1.0"
    assert output =~ "section.gone_with_the_tag: removed without being deprecated first"
    assert output =~ "Deprecate a field first"
    assert worktrees(dir) == 1
  end

  test "a field deprecated in the tag may be removed", %{tmp_dir: dir} do
    init_project(dir, @catalogue_with_deprecated_field)
    tag(dir, "v0.1.0")
    commit_catalogue(dir, @catalogue_without_field)

    {output, status} = compat(dir)

    assert status == 0, output
    assert output =~ "compatible with v0.1.0"
    assert worktrees(dir) == 1
  end

  test "without a v* tag there is nothing to compare", %{tmp_dir: dir} do
    init_project(dir, @catalogue_with_gone_field)
    tag(dir, "not-a-version")
    commit_catalogue(dir, @catalogue_without_field)

    {output, status} = compat(dir)

    assert status == 0, output
    assert output =~ "no v* tag yet, nothing to compare"
  end

  test "--against picks the tag instead of the last one", %{tmp_dir: dir} do
    init_project(dir, @catalogue_with_gone_field)
    tag(dir, "v0.1.0")
    commit_catalogue(dir, @catalogue_without_field)
    tag(dir, "v0.2.0")

    assert {output, 0} = compat(dir)
    assert output =~ "compatible with v0.2.0"

    {output, status} = compat(dir, ["--against", "v0.1.0"])

    assert status != 0
    assert output =~ "breaking changes against v0.1.0"
  end

  test "a tag whose catalogue doesn't compile fails with its output", %{tmp_dir: dir} do
    init_project(dir, "defmodule MicaBff.Blocks do\n  this does not compile\n")
    tag(dir, "v0.1.0")
    commit_catalogue(dir, @catalogue_without_field)

    {output, status} = compat(dir)

    assert status != 0
    assert output =~ "could not read the catalogue at v0.1.0"
    assert output =~ "blocks.ex"
    assert worktrees(dir) == 1
  end

  test "a tag that doesn't exist fails", %{tmp_dir: dir} do
    init_project(dir, @catalogue_without_field)

    {output, status} = compat(dir, ["--against", "v9.9.9"])

    assert status != 0
    assert output =~ "could not check out v9.9.9"
  end

  test "outside a git repository it fails instead of passing", %{tmp_dir: dir} do
    copy_project(dir, @catalogue_without_field)

    # tmp_dir sits inside this repo's checkout; stop git from finding it.
    {output, status} =
      System.cmd("mix", ["bff.compat"],
        cd: dir,
        stderr_to_stdout: true,
        env: [{"GIT_CEILING_DIRECTORIES", Path.dirname(dir)}]
      )

    assert status != 0
    assert output =~ "git failed"
  end

  defp init_project(dir, catalogue) do
    copy_project(dir, catalogue)
    git!(dir, ["init", "--quiet"])
    commit_all(dir)
  end

  defp copy_project(dir, catalogue) do
    File.cp!("mix.exs", Path.join(dir, "mix.exs"))
    File.cp!(".tool-versions", Path.join(dir, ".tool-versions"))
    File.cp_r!("lib", Path.join(dir, "lib"))
    File.write!(Path.join(dir, ".gitignore"), "/_build/\n")
    File.write!(Path.join(dir, "lib/mica_bff/blocks.ex"), catalogue)
  end

  defp commit_catalogue(dir, catalogue) do
    File.write!(Path.join(dir, "lib/mica_bff/blocks.ex"), catalogue)
    commit_all(dir)
  end

  defp commit_all(dir) do
    git!(dir, ["add", "--all"])
    git!(dir, ["commit", "--quiet", "--allow-empty", "--message", "catalogue"])
  end

  defp tag(dir, name), do: git!(dir, ["tag", name])

  defp worktrees(dir) do
    dir
    |> git!(["worktree", "list", "--porcelain"])
    |> String.split("\n")
    |> Enum.count(&String.starts_with?(&1, "worktree "))
  end

  defp compat(dir, args \\ []) do
    System.cmd("mix", ["bff.compat" | args], cd: dir, stderr_to_stdout: true)
  end

  defp git!(dir, args) do
    identity = [
      "-c",
      "user.name=test",
      "-c",
      "user.email=test@example.com",
      "-c",
      "commit.gpgsign=false",
      "-c",
      "tag.gpgsign=false"
    ]

    {output, 0} = System.cmd("git", identity ++ args, cd: dir, stderr_to_stdout: true)
    output
  end
end
