defmodule GoodFlows.Pools.Provisioner do
  @moduledoc """
  The member lifecycle work run by `GoodFlows.Pools.ProvisionMemberJob`,
  `GoodFlows.Pools.ResetMemberJob`, and `GoodFlows.Pools.DestroyMemberJob`.

  Each entry point claims the member (state plus a `NULL` owner) with a
  fresh owner id registered in `GoodFlows.Spry.Executions`, uses the
  member's encrypted creation-credential snapshot (never the account's
  current token), bounds every Sprites action, and finishes with a fenced
  transition. A worker that lost its claim changes nothing.

  **Provision**: under the pool row lock, the pool's current setup is
  captured; if its `setup_version` is no longer the member's, the member is
  retired before any work. Then: create the sprite, run each setup item
  with `bash -c` (fail fast on a non-zero exit, error, or timeout), detect
  the architecture with `uname -m`, write the packaged helper (at most
  16 MiB, one filesystem request) to `#{"/usr/local/lib/goodflows/gf-transfer"}`, verify
  its SHA-256 and version handshake, record `helper_version`, take the
  golden checkpoint (unique comment `gfp-golden:<member>:<nonce>`), and
  become `idle`. The whole provision is bounded by `provision_timeout_ms`.
  Any failure makes the member `broken` and bumps the pool's failure streak
  and `next_provision_at` backoff; success clears them.

  **Reset**: best-effort `gf-transfer cleanup`, then restore the golden
  checkpoint (which ends every process), then `idle`; a failed or
  timed-out restore makes the member `broken`.

  **Destroy**: destroy the sprite and delete the row; `not_found` under the
  member's own credential counts as success. Other failures keep the row
  with a sanitized error and a retry time. An authorization failure (`401`
  or `403`: the creation credential was revoked) that brings the member's
  failure count to 5 makes it `abandoned` instead: it is no longer
  retried, the API shows it, and pool deletion forgets it (logging its
  name), since no cleanup with another token is ever attempted.

  Reset and destroy run even while pools are disabled, so a rollback with
  `POOLS_ENABLED=false` still cleans up; provisioning does not.
  """
  import Ecto.Query

  require Logger

  alias GoodFlows.Pools.{Config, Events, Grants, Member, Members, Pool, Transfers}
  alias GoodFlows.Repo
  alias GoodFlows.Spry.Config, as: SpryConfig
  alias GoodFlows.Spry.{Executions, Sprites}

  @backoff_base_ms 30_000
  @backoff_max_ms 30 * 60_000
  @abandon_after_failures 5

  @doc "Provisions a `provisioning` member. Returns a JSON-safe summary."
  @spec provision(Ecto.UUID.t()) :: map()
  def provision(member_id) do
    with_owner(:provision, fn owner_id ->
      case Members.claim(member_id, "provisioning", owner_id, :provision) do
        {:ok, member} -> claimed_provision(Members.get(member.id), owner_id)
        :not_claimable -> "skipped"
      end
    end)
  end

  defp claimed_provision(member, owner_id) do
    case capture_setup(member) do
      {:ok, setup} ->
        deadline = System.monotonic_time(:millisecond) + Config.provision_timeout_ms()

        result =
          safely(fn -> build(member, setup, deadline) end)
          |> case do
            {:ok, _} = ok -> ok
            {:error, :timeout} -> {:error, "provisioning exceeded its time budget"}
            other -> other
          end

        finish_provision(member, owner_id, result)

      :stale ->
        Members.transition(member.id, "provisioning", owner_id,
          state: "destroying",
          owner_id: nil
        )

        Members.enqueue("destroying", member.id)
        "stale"
    end
  end

  # The setup of the member's captured version, read under the pool lock.
  defp capture_setup(member) do
    Repo.transact(fn ->
      case Pool |> where(id: ^member.pool_id) |> lock("FOR SHARE") |> Repo.one() do
        %Pool{setup_version: version, setup: setup, deleting_at: nil}
        when version == member.setup_version ->
          {:ok, setup}

        _other ->
          {:error, :stale}
      end
    end)
    |> case do
      {:ok, setup} -> {:ok, setup}
      {:error, :stale} -> :stale
    end
  end

  defp build(member, setup, deadline) do
    client = Members.client(member)

    with :ok <- step(Sprites.create(client, member.name, timeout: remaining(deadline)), "create"),
         :ok <- run_setup(client, member.name, setup, deadline),
         {:ok, arch, artifact} <- architecture(client, member.name, deadline),
         :ok <- install_helper(client, member.name, artifact, deadline),
         {:ok, helper_version} <- verify_helper(client, member.name, artifact, deadline),
         {:ok, checkpoint} <- checkpoint(client, member, deadline) do
      {:ok, %{arch: arch, helper_version: helper_version, checkpoint: checkpoint}}
    end
  end

  defp remaining(deadline) do
    left = deadline - System.monotonic_time(:millisecond)

    if left <= 0,
      do: throw({:provision, {:error, :timeout}}),
      else: min(left, SpryConfig.step_timeout_ms())
  end

  defp step(:ok, _what), do: :ok
  defp step({:error, :timeout}, what), do: {:error, "#{what} timed out"}

  defp step({:error, error}, what),
    do: {:error, "#{what} failed: #{Sprites.error_message(error)}"}

  defp run_setup(client, name, setup, deadline) do
    setup
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {line, index}, :ok ->
      case Sprites.exec(client, name, line, timeout: remaining(deadline)) do
        {:ok, %{exit_code: 0}} ->
          {:cont, :ok}

        {:ok, %{exit_code: code}} ->
          {:halt, {:error, "setup[#{index}] exited with code #{code}"}}

        {:error, :timeout} ->
          {:halt, {:error, "setup[#{index}] timed out"}}

        {:error, error} ->
          {:halt, {:error, "setup[#{index}] failed: #{Sprites.error_message(error)}"}}
      end
    end)
  end

  defp architecture(client, name, deadline) do
    case Sprites.exec(client, name, "uname -m", timeout: remaining(deadline)) do
      {:ok, %{exit_code: 0, output: output}} ->
        arch = String.trim(output)

        case Config.helper_artifact(arch) do
          {:ok, artifact} ->
            {:ok, arch, artifact}

          {:error, :unsupported_architecture} ->
            {:error, "unsupported_architecture: #{String.slice(arch, 0, 64)}"}

          {:error, :helper_unavailable} ->
            {:error, "the transfer helper artifact is unavailable"}
        end

      other ->
        step(other, "architecture detection")
    end
  end

  # The path is the packaged helper artifact dir joined with a manifest entry; never user input.
  # sobelow_skip ["Traversal.FileModule"]
  defp install_helper(client, name, artifact, deadline) do
    path = Path.join(Config.helper_artifact_dir(), artifact.path)

    with {:ok, bytes} <- File.read(path),
         true <- byte_size(bytes) == artifact.size || {:error, "helper artifact size mismatch"},
         true <-
           byte_size(bytes) <= Config.bootstrap_max_bytes() ||
             {:error, "helper artifact exceeds the 16 MiB bootstrap limit"},
         true <-
           sha256(bytes) == artifact.sha256 || {:error, "helper artifact checksum mismatch"} do
      Sprites.write_file(client, name, Transfers.helper_path(), bytes,
        timeout: remaining(deadline)
      )
      |> case do
        :ok -> :ok
        {:error, :too_large} -> {:error, "helper artifact exceeds the 16 MiB bootstrap limit"}
        other -> step(other, "helper install")
      end
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, _posix} -> {:error, "the transfer helper artifact is unavailable"}
    end
  end

  # Verifies the installed bytes and the version handshake after setup.
  defp verify_helper(client, name, artifact, deadline) do
    line = "sha256sum #{Transfers.helper_path()} && #{Transfers.helper_path()} version"

    case Sprites.exec(client, name, line, timeout: remaining(deadline)) do
      {:ok, %{exit_code: 0, output: output}} ->
        with true <-
               String.contains?(output, artifact.sha256) ||
                 {:error, "installed helper checksum mismatch"},
             {:ok, handshake} <- handshake(output),
             true <-
               handshake["protocol"] == Config.protocol_version() ||
                 {:error,
                  "incompatible transfer helper protocol #{inspect(handshake["protocol"])}"},
             {:ok, manifest} <- Config.helper_manifest(),
             true <-
               handshake["version"] == manifest.version ||
                 {:error, "transfer helper version mismatch"} do
          {:ok, Config.helper_version(manifest)}
        end

      other ->
        step(other, "helper verification")
    end
  end

  defp handshake(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.find_value(
      {:error, "the transfer helper did not answer the version handshake"},
      fn line ->
        case Jason.decode(line) do
          {:ok, %{"name" => "gf-transfer"} = map} -> {:ok, map}
          _ -> nil
        end
      end
    )
  end

  defp checkpoint(client, member, deadline) do
    nonce = 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    comment = "gfp-golden:#{member.id}:#{nonce}"

    case Sprites.create_checkpoint(client, member.name,
           comment: comment,
           timeout: remaining(deadline)
         ) do
      {:ok, id} -> {:ok, id}
      other -> step(other, "checkpoint")
    end
  end

  defp finish_provision(member, owner_id, {:ok, built}) do
    case Members.transition(member.id, "provisioning", owner_id,
           state: "idle",
           idle_since: DateTime.utc_now(),
           owner_id: nil,
           operation_deadline_at: nil,
           arch: built.arch,
           helper_version: built.helper_version,
           golden_checkpoint_id: built.checkpoint,
           last_error: nil
         ) do
      :ok ->
        Pool
        |> where(id: ^member.pool_id)
        |> Repo.update_all(
          set: [provision_failures: 0, next_provision_at: nil, last_provision_error: nil]
        )

        Grants.grant(member.pool_id)
        Events.nudge(member.pool_id)
        "idle"

      :stale ->
        "lost"
    end
  end

  defp finish_provision(member, owner_id, {:error, message}) do
    case fail_provision(member, owner_id, sanitize(message)) do
      :ok -> "broken"
      :stale -> "lost"
    end
  end

  @doc """
  Marks a `provisioning` member `broken` (fenced on `owner_id`, or `:any`)
  and records the failure on its pool's streak and backoff, in one
  transaction under the pool row lock, so no reconciler tick can provision
  again in between without the backoff. Used for a failed provision and by
  the reconciler for a provision whose worker was lost.
  """
  @spec fail_provision(Member.t(), String.t() | :any, String.t()) :: :ok | :stale
  def fail_provision(%Member{} = member, owner_id, message) do
    Repo.transact(fn ->
      pool = Pool |> where(id: ^member.pool_id) |> lock("FOR UPDATE") |> Repo.one()
      break_and_record(member, owner_id, message, pool)
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, :stale} -> :stale
    end
  end

  defp break_and_record(member, owner_id, message, pool) do
    case Members.break(member, "provisioning", owner_id, message) do
      :ok ->
        if pool, do: record_pool_failure(pool, message)
        {:ok, :ok}

      :stale ->
        {:error, :stale}
    end
  end

  defp record_pool_failure(pool, message) do
    failures = pool.provision_failures + 1
    delay = min(@backoff_base_ms * Integer.pow(2, min(failures - 1, 10)), @backoff_max_ms)

    pool
    |> Ecto.Changeset.change(
      provision_failures: failures,
      next_provision_at: DateTime.add(DateTime.utc_now(), delay, :millisecond),
      last_provision_error: message
    )
    |> Repo.update!()
  end

  @doc "Resets a `resetting` member to its golden checkpoint."
  @spec reset(Ecto.UUID.t()) :: map()
  def reset(member_id) do
    with_owner(:reset, fn owner_id ->
      case Members.claim(member_id, "resetting", owner_id, :reset) do
        {:ok, member} -> claimed_reset(Members.get(member.id), owner_id)
        :not_claimable -> "skipped"
      end
    end)
  end

  defp claimed_reset(member, owner_id) do
    client = Members.client(member)
    timeout = SpryConfig.step_timeout_ms()

    # Best effort: restore discards the helper's private state anyway.
    _ =
      Sprites.exec(
        client,
        member.name,
        "#{Transfers.helper_path()} cleanup --state-dir #{Transfers.state_dir()}",
        timeout: min(timeout, 60_000)
      )

    case safely(fn ->
           Sprites.restore_checkpoint(client, member.name, member.golden_checkpoint_id,
             timeout: timeout
           )
         end) do
      :ok ->
        case Members.transition(member.id, "resetting", owner_id,
               state: "idle",
               idle_since: DateTime.utc_now(),
               owner_id: nil,
               operation_deadline_at: nil,
               session_id: nil,
               workspace_ready_generation: nil,
               last_error: nil
             ) do
          :ok ->
            Grants.grant(member.pool_id)
            Events.nudge(member.pool_id)
            "idle"

          :stale ->
            "lost"
        end

      {:error, :timeout} ->
        broken(member, owner_id, "resetting", "restore timed out; the remote outcome is unknown")

      {:error, error} ->
        broken(member, owner_id, "resetting", "restore failed: #{Sprites.error_message(error)}")
    end
  end

  defp broken(member, owner_id, from, message) do
    case Members.break(member, from, owner_id, sanitize(message)) do
      :ok -> "broken"
      :stale -> "lost"
    end
  end

  @doc "Destroys a `destroying` member's sprite and removes its row."
  @spec destroy(Ecto.UUID.t()) :: map()
  def destroy(member_id) do
    with_owner(:destroy, fn owner_id ->
      case Members.claim(member_id, "destroying", owner_id, :destroy) do
        {:ok, member} -> claimed_destroy(Members.get(member.id), owner_id)
        :not_claimable -> "skipped"
      end
    end)
  end

  defp claimed_destroy(member, owner_id) do
    client = Members.client(member)

    result =
      safely(fn ->
        Sprites.destroy(client, member.name, timeout: SpryConfig.step_timeout_ms())
      end)

    if result == :ok or match?({:error, %{status: 404}}, result) do
      {count, _} =
        Member
        |> where([m], m.id == ^member.id and m.state == "destroying" and m.owner_id == ^owner_id)
        |> Repo.delete_all()

      Events.nudge(member.pool_id)
      if count == 1, do: "destroyed", else: "lost"
    else
      destroy_failed(member, owner_id, result)
    end
  end

  defp destroy_failed(member, owner_id, result) do
    message =
      case result do
        {:error, :timeout} -> "destroy timed out"
        {:error, error} -> "destroy failed: #{Sprites.error_message(error)}"
      end

    if unauthorized?(result) and member.failures + 1 >= @abandon_after_failures,
      do: abandon(member, owner_id, message),
      else: retry_destroy(member, owner_id, message)
  end

  defp unauthorized?({:error, %{status: status}}) when status in [401, 403], do: true
  defp unauthorized?(_result), do: false

  defp abandon(member, owner_id, message) do
    case Members.transition(member.id, "destroying", owner_id,
           state: "abandoned",
           owner_id: nil,
           operation_deadline_at: nil,
           last_error: sanitize(message),
           failures: member.failures + 1,
           next_attempt_at: nil
         ) do
      :ok ->
        Logger.error(
          "Pools: member #{member.name} of pool #{member.pool_id} is abandoned: its sprite " <>
            "could not be destroyed with its creation credential (#{sanitize(message)}). " <>
            "It may still exist remotely; remove it in Sprites and then with " <>
            "GoodFlows.Pools.Operator.forget_member/1."
        )

        Events.nudge(member.pool_id)
        "abandoned"

      :stale ->
        "lost"
    end
  end

  defp retry_destroy(member, owner_id, message) do
    Members.transition(member.id, "destroying", owner_id,
      owner_id: nil,
      operation_deadline_at: nil,
      last_error: sanitize(message),
      failures: member.failures + 1,
      next_attempt_at:
        DateTime.add(DateTime.utc_now(), backoff(member.failures + 1), :millisecond)
    )

    "retry"
  end

  defp backoff(failures),
    do: min(@backoff_base_ms * Integer.pow(2, min(failures - 1, 10)), @backoff_max_ms)

  ## Helpers

  # Provisioning needs pools enabled; reset and destroy only clean up, so
  # they also run while pools are disabled.
  defp with_owner(kind, fun) do
    if kind != :provision or Config.enabled?() do
      owner_id = Executions.new_owner_id()
      :ok = Executions.register(owner_id)

      try do
        %{"result" => fun.(owner_id)}
      after
        Executions.unregister(owner_id)
      end
    else
      %{"result" => "disabled"}
    end
  end

  defp safely(fun) do
    fun.()
  rescue
    error -> {:error, Exception.message(error)}
  catch
    {:provision, result} -> result
    :exit, _reason -> {:error, "the operation exited"}
  end

  defp sanitize(message) when is_binary(message),
    do: message |> String.replace_invalid() |> String.slice(0, 1_000)

  defp sanitize(message), do: inspect(message) |> String.slice(0, 1_000)

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
