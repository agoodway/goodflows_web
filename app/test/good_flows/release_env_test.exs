defmodule GoodFlows.ReleaseEnvTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  # Everything rel/env.sh.eex reads, so the shell running the tests cannot
  # change a case.
  @cleared Map.new(
             ~w(RELEASE_COMMAND RELEASE_COOKIE RELEASE_DISTRIBUTION RELEASE_NODE RELEASE_HOST
                FLY_MACHINE_ID FLY_APP_NAME),
             &{&1, nil}
           )

  setup %{tmp_dir: tmp_dir} do
    script = Path.join(tmp_dir, "env.sh")
    File.write!(script, EEx.eval_file("rel/env.sh.eex", assigns: [release: %{name: :good_flows}]))
    %{script: script}
  end

  # Sources the script the way bin/good_flows does, after it exports RELEASE_COMMAND.
  defp source(script, env) do
    System.cmd("sh", ["-c", ~s(. "$1"), "sh", script],
      env: Map.merge(@cleared, env),
      stderr_to_stdout: true
    )
  end

  describe "RELEASE_COOKIE" do
    test "is required by every command that starts or reaches a distributed node", %{
      script: script
    } do
      for command <- ~w(start start_iex daemon daemon_iex remote rpc restart stop pid) do
        assert {output, 1} = source(script, %{"RELEASE_COMMAND" => command})
        assert output =~ "RELEASE_COOKIE is not set"
      end

      assert {_output, 1} =
               source(script, %{"RELEASE_COMMAND" => "start", "RELEASE_COOKIE" => ""})

      assert {"", 0} =
               source(script, %{"RELEASE_COMMAND" => "start", "RELEASE_COOKIE" => "secret"})
    end

    test "is not required where no distribution starts", %{script: script} do
      # bin/migrate runs `eval`, also as the Fly release command.
      assert {"", 0} = source(script, %{"RELEASE_COMMAND" => "eval"})
      assert {"", 0} = source(script, %{"RELEASE_COMMAND" => "version"})

      assert {"", 0} =
               source(script, %{"RELEASE_COMMAND" => "start", "RELEASE_DISTRIBUTION" => "none"})
    end
  end
end
