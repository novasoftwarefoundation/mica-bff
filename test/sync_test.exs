defmodule MicaBff.SyncTest do
  # Runs .github/sync.sh, the shell steps of the sync job in ci.yml, against local git repos and a
  # stubbed gh: a target repo whose develop holds `struct A {}`, maybe a mica-bff/sync branch, and the
  # code this run generated.
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @script Path.expand(".github/sync.sh")
  @sha "1111111111111111111111111111111111111111"

  # Answers as gh does: `pulls?head=eyra:…` counts same-repo PRs only, `pr list --head` counts fork
  # PRs too, and `pr close <branch>` only finds a same-repo PR.
  @gh ~S"""
  #!/usr/bin/env bash
  case "$*" in
    "api repos/$GITHUB_REPOSITORY/git/ref/heads/main --jq .object.sha") echo "$MAIN" ;;
    "api repos/$REPO/pulls?head=eyra:mica-bff/sync&state=open --jq length") echo "$PRS" ;;
    "pr list -R $REPO --head mica-bff/sync --state open --json number --jq length") echo $((PRS + FORK_PRS)) ;;
    "pr close mica-bff/sync -R $REPO --delete-branch "*)
      [ "$PRS" != 0 ] || { echo 'no pull requests found for branch "mica-bff/sync"' >&2; exit 1; }
      git -C "$UPSTREAM" update-ref -d refs/heads/mica-bff/sync ;;
    "api -X DELETE repos/$REPO/git/refs/heads/mica-bff/sync") git -C "$UPSTREAM" update-ref -d refs/heads/mica-bff/sync ;;
    *) echo "unexpected gh call: $*" >&2; exit 2 ;;
  esac
  """

  test "new code opens a PR, changed code updates it", %{tmp_dir: dir} do
    assert sync(dir, generated: "struct B {}") == :update
    assert sync(dir, branch: "struct B {}", prs: 1, generated: "struct C {}") == :update
  end

  test "the same code as the open PR, or a header-only change, does nothing", %{tmp_dir: dir} do
    assert sync(dir, branch: "struct B {}", prs: 1, generated: "struct B {}") == :nothing
    assert sync(dir, generated: "struct A {}") == :nothing
  end

  test "code back to develop closes the PR and deletes the branch", %{tmp_dir: dir} do
    assert sync(dir, branch: "struct B {}", prs: 1, generated: "struct A {}") == :closed
  end

  # The sync once compared with the branch alone, so a branch left without a PR (a cancelled run,
  # a PR closed by hand) blocked the PR for that code, also on a re-run.
  test "a sync branch without an open PR gets its PR again", %{tmp_dir: dir} do
    assert sync(dir, branch: "struct B {}", prs: 0, generated: "struct B {}") == :update
  end

  # The close step once counted fork PRs, then gh pr close found no PR and failed.
  test "a fork PR with the sync branch's name doesn't stop the branch's removal", %{tmp_dir: dir} do
    assert sync(dir, branch: "struct B {}", prs: 0, fork_prs: 1, generated: "struct A {}") ==
             :closed
  end

  # Runs reach the sync in the order their tests finish, so an older run once synced its older code,
  # or closed the newer PR when its code matched develop.
  test "a commit that is no longer the tip of main doesn't sync", %{tmp_dir: dir} do
    newer = String.duplicate("2", 40)
    assert sync(dir, main: newer, generated: "struct B {}") == :skipped

    assert sync(dir, main: newer, branch: "struct C {}", prs: 1, generated: "struct A {}") ==
             :skipped
  end

  # An older run's sync once joined the concurrency group, cancelled the newest run's running sync, and
  # then skipped. GitHub decides which job runs, waits or is cancelled, so this checks the settings that
  # keep an older run out of the group and the newest sync from being cancelled. No YAML parser among
  # the deps: the sync job is the lines under `  sync:` up to the next job, without comments.
  test "an older run can't cancel the newest sync" do
    sync =
      ".github/workflows/ci.yml"
      |> File.read!()
      |> String.split("\n")
      |> Enum.drop_while(&(&1 != "  sync:"))
      |> Enum.drop(1)
      |> Enum.take_while(&(not String.match?(&1, ~r/^  \S/)))
      |> Enum.reject(&String.match?(&1, ~r/^\s*#/))
      |> Enum.join("\n")

    missing =
      for {setting, pattern} <- [
            {"needs: tip", ~r/^    needs: (tip|\[.*\btip\b.*\])$/m},
            {"if: needs.tip.outputs.latest == 'true'",
             ~r/^    if: needs\.tip\.outputs\.latest == 'true'$/m},
            {"concurrency: cancel-in-progress: false",
             ~r/^    concurrency:\n(      .*\n)*      cancel-in-progress: false$/m},
            {"timeout-minutes", ~r/^    timeout-minutes: \d+$/m}
          ],
          not (sync =~ pattern),
          do: setting

    assert missing == [], "the sync job in ci.yml lacks: #{Enum.join(missing, ", ")}"
  end

  # The steps as ci.yml wires them: tip, then compare, then close when compare says so.
  # Returns :skipped, :nothing, :update or :closed (the sync branch is gone afterwards).
  defp sync(dir, opts) do
    dir = Path.join(dir, "#{System.unique_integer([:positive])}")
    upstream = Path.join(dir, "upstream.git")
    target = Path.join(dir, "target")
    File.mkdir_p!(Path.join(dir, "bin"))
    File.write!(Path.join(dir, "bin/gh"), @gh)
    File.chmod!(Path.join(dir, "bin/gh"), 0o755)

    git!(dir, ~w(init -q --bare #{upstream}))
    seed = Path.join(dir, "seed")
    git!(dir, ~w(init -q -b develop #{seed}))
    write!(seed, "0000000", "struct A {}")
    git!(seed, ~w(add -A))
    git!(seed, ~w(commit -qm develop))
    git!(seed, ~w(push -q #{upstream} develop))

    if branch = opts[:branch] do
      git!(seed, ~w(checkout -qb mica-bff/sync))
      write!(seed, "0000001", branch)
      git!(seed, ~w(commit -qam sync))
      git!(seed, ~w(push -q #{upstream} mica-bff/sync))
    end

    git!(dir, ~w(clone -q --depth 1 -b develop file://#{upstream} #{target}))
    write!(target, String.slice(@sha, 0, 7), Keyword.fetch!(opts, :generated))

    output = Path.join(dir, "output")

    env = [
      {"PATH", Path.join(dir, "bin") <> ":" <> System.get_env("PATH")},
      {"GITHUB_OUTPUT", output},
      {"GITHUB_SHA", @sha},
      {"GITHUB_REPOSITORY", "novasoftwarefoundation/mica-bff"},
      {"REPO", "eyra/mono"},
      {"OUT", "out"},
      {"GH_TOKEN", "x"},
      {"UPSTREAM", upstream},
      {"MAIN", opts[:main] || @sha},
      {"PRS", "#{opts[:prs] || 0}"},
      {"FORK_PRS", "#{opts[:fork_prs] || 0}"}
    ]

    step = fn name, cd ->
      File.write!(output, "")

      {out, status} =
        System.cmd("bash", [@script, name], cd: cd, env: env, stderr_to_stdout: true)

      assert status == 0, "sync.sh #{name} failed:\n#{out}"
      File.read!(output)
    end

    with "latest=true\n" <- step.("tip", dir) do
      case step.("compare", target) do
        "update=true\n" ->
          :update

        "close=true\n" ->
          step.("close", dir)

          {_, status} =
            System.cmd("git", ~w(rev-parse -q --verify refs/heads/mica-bff/sync), cd: upstream)

          assert status != 0, "the sync branch is still there"
          :closed

        "" ->
          :nothing
      end
    else
      _ -> :skipped
    end
  end

  defp write!(repo, sha, code) do
    File.mkdir_p!(Path.join(repo, "out"))

    File.write!(
      Path.join(repo, "out/BFF.swift"),
      "// Generated by mica-bff 0.1.0 at #{sha} (mix bff.gen.swift). Do not edit.\n#{code}\n"
    )
  end

  defp git!(cd, args) do
    env = [
      {"GIT_AUTHOR_NAME", "test"},
      {"GIT_AUTHOR_EMAIL", "test@example.com"},
      {"GIT_COMMITTER_NAME", "test"},
      {"GIT_COMMITTER_EMAIL", "test@example.com"}
    ]

    {out, status} = System.cmd("git", args, cd: cd, env: env, stderr_to_stdout: true)
    assert status == 0, "git #{Enum.join(args, " ")} failed:\n#{out}"
  end
end
