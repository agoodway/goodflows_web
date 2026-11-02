defmodule GoodFlows.Pools.Config do
  @moduledoc """
  Runtime settings for Sprite pools, read from `config :good_flows, GoodFlows.Pools`.
  In production `config/runtime.exs` maps `POOL_*` environment variables
  onto most of them (see `app/.env.sample`); the transfer tuning
  (`transfer_chunk_bytes` aside), helper, report, and interval settings
  (`transfer_ack_timeout_ms`, `transfer_attempts`, `transfer_backoff_ms`,
  `helper_idle_timeout_ms`, `report_fetch_timeout_ms`, `report_max_files`,
  `reconcile_interval_ms`, `heartbeat_interval_ms`, `owner_rpc_timeout_ms`)
  are config-only:

    * `:enabled` - master switch (env `POOLS_ENABLED`, default `true`). When
      off, or when the helper artifact manifest is missing or invalid, pool
      reads and writes (except pool deletion), session, workspace, and
      report routes respond `503`, the pool socket refuses connections, and
      no member is granted or provisioned; the reconciler still expires
      sessions, resets and destroys members, and finishes pool deletions,
      so a rollback can be cleaned up.
    * `:require_helper_manifest` - when `true` (set in production when
      pools are enabled), a missing or invalid helper manifest stops the
      node at boot instead of disabling pools (default `false`)
    * `:max_members_cap` - largest allowed pool `max_members` (default 32)
    * `:provision_timeout_ms` - total budget for provisioning one member,
      setup through golden checkpoint (default 30 minutes)
    * `:workspace_max_bytes` - compressed workspace upload limit (default 256 MiB)
    * `:workspace_max_expanded_bytes` - expanded archive limit (default 2 GiB)
    * `:workspace_max_entries` - archive entry limit (default 100,000)
    * `:archive_validation_timeout_ms` - archive preflight deadline (default 60 s)
    * `:workspace_read_timeout_ms` - upload body read deadline (default 300 s)
    * `:workspace_max_concurrent_uploads_per_account` - per-account concurrent
      uploads on a node (default 1). Enforced per node, not cluster-wide: an
      account can have this many uploads in flight on each node (each also
      reserves the node's spool budget), which bounds every node's disk and
      memory use, the thing the cap protects
    * `:transfer_chunk_bytes` - helper protocol payload maximum (default and
      ceiling 1 MiB)
    * `:transfer_concurrency` - node-wide active transfers (default 2)
    * `:transfer_ack_timeout_ms` - wait for one helper acknowledgement (default 30 s)
    * `:transfer_attempts` - attempts per transfer (default 5)
    * `:transfer_backoff_ms` - first retry delay, doubled per attempt (default 500)
    * `:helper_idle_timeout_ms` - helper exits after this long without frames
      (default 60 s); the server waits at least this long (plus the ack
      timeout) for a helper's first frame, since a replacement invocation
      may wait that long for the previous one's lock
    * `:helper_extract_timeout_ms` - the helper's wall-clock budget for
      validating and extracting a workspace in the member (default 300 s;
      the server's own preflight uses `archive_validation_timeout_ms`)
    * `:report_fetch_timeout_ms` - wait for a verified report before `503`
      (default 60 s)
    * `:report_max_files` - report manifest entries per exec (default 100)
    * `:spool_dir` - node-local spool root (default `goodflows-pools` under
      `System.tmp_dir!/0`)
    * `:spool_max_bytes` - node-wide spool budget (default 2 GiB)
    * `:spool_account_max_bytes` - one account's share of a node's spool
      budget, uploads and reports together (default 1 GiB; at least
      `workspace_max_bytes`)
    * `:helper_artifact_dir` - packaged `gf-transfer` artifacts with their
      `manifest.json` (default `priv/gf-transfer` of the app)
    * `:disconnect_grace_ms` - session expiry without a joined client (default 60 s)
    * `:max_session_lifetime_ms` - session lifetime cap (default 6 hours)
    * `:acquire_timeout_max_ms` - largest `acquire_timeout_ms` (default 10 minutes)
    * `:exec_max_ms` - exec timeout cap (default 1 hour)
    * `:exec_buffer_bytes` - per-exec replay buffer (default 1 MiB)
    * `:reconcile_interval_ms` - reconciler tick (default 15 s)
    * `:heartbeat_interval_ms` - channel `last_seen_at` refresh (default 15 s)
    * `:owner_rpc_timeout_ms` - bounded calls to a session owner node (default 5 s)
    * `:session_retention_ms` - ended sessions (and their execs) are deleted
      this long after they ended (default 30 days)
    * `:fingerprint_secret` - the secret keying credential fingerprints
      (`GoodFlows.Pools.Credentials`); production sets it from
      `POOL_FINGERPRINT_SECRET`, falling back to `SECRET_KEY_BASE`

  Report files are capped at 32 MiB and outputs at 65,537 bytes; those are
  part of the wire contract and not configurable.

  The PgFlow hard timeouts of the member jobs are fixed at compile time
  (`provision_job_timeout_seconds/0`, `member_job_timeout_seconds/0`).
  `validate!/0` runs at startup, refuses settings those timeouts cannot
  cover, and loads the helper manifest; a missing or invalid manifest logs
  an error and disables pools instead of stopping the node.
  """

  require Logger

  alias GoodFlows.Spry.Config, as: SpryConfig

  @mib 1_048_576

  @defaults [
    enabled: true,
    max_members_cap: 32,
    provision_timeout_ms: 30 * 60_000,
    workspace_max_bytes: 256 * @mib,
    workspace_max_expanded_bytes: 2 * 1024 * @mib,
    workspace_max_entries: 100_000,
    archive_validation_timeout_ms: 60_000,
    workspace_read_timeout_ms: 300_000,
    workspace_max_concurrent_uploads_per_account: 1,
    transfer_chunk_bytes: @mib,
    transfer_concurrency: 2,
    transfer_ack_timeout_ms: 30_000,
    transfer_attempts: 5,
    transfer_backoff_ms: 500,
    helper_idle_timeout_ms: 60_000,
    helper_extract_timeout_ms: 300_000,
    report_fetch_timeout_ms: 60_000,
    report_max_files: 100,
    spool_dir: nil,
    spool_max_bytes: 2 * 1024 * @mib,
    spool_account_max_bytes: 1024 * @mib,
    helper_artifact_dir: nil,
    disconnect_grace_ms: 60_000,
    max_session_lifetime_ms: 6 * 60 * 60_000,
    acquire_timeout_max_ms: 10 * 60_000,
    exec_max_ms: 60 * 60_000,
    exec_buffer_bytes: @mib,
    reconcile_interval_ms: 15_000,
    heartbeat_interval_ms: 15_000,
    owner_rpc_timeout_ms: 5_000,
    session_retention_ms: 30 * 24 * 60 * 60_000,
    require_helper_manifest: false,
    fingerprint_secret: nil
  ]

  @positive_keys @defaults
                 |> Keyword.keys()
                 |> Kernel.--([
                   :enabled,
                   :spool_dir,
                   :helper_artifact_dir,
                   :require_helper_manifest,
                   :fingerprint_secret
                 ])

  @report_max_bytes 32 * @mib
  @outputs_max_bytes 65_537
  @bootstrap_max_bytes 16_777_216
  @protocol_version 1

  # Provisioning: setup items, helper bootstrap, and checkpoint must fit in
  # the job timeout with this margin for finalization.
  @provision_job_timeout_seconds 2_400
  # Reset and destroy: one step-bounded Sprites action plus cleanup.
  @member_job_timeout_seconds 2_400
  @job_margin_ms 5 * 60_000

  @manifest_key {__MODULE__, :helper_manifest}

  @typedoc "One packaged helper binary from `manifest.json`."
  @type artifact :: %{
          target: String.t(),
          arch: String.t(),
          path: String.t(),
          sha256: String.t(),
          size: non_neg_integer()
        }

  @typedoc "The validated helper manifest."
  @type manifest :: %{version: String.t(), protocol: pos_integer(), artifacts: [artifact()]}

  for key <- @positive_keys do
    @doc "The configured `#{inspect(key)}` (default `#{inspect(Keyword.fetch!(@defaults, key))}`)."
    @spec unquote(key)() :: pos_integer()
    def unquote(key)(), do: get(unquote(key))
  end

  @doc "Whether pools are switched on in configuration (`POOLS_ENABLED`)."
  @spec configured_enabled?() :: boolean()
  def configured_enabled?, do: get(:enabled) not in [false, "false", "0"]

  @doc """
  Whether pools are usable on this node: switched on and backed by a valid
  helper manifest (loaded by `validate!/0` or `load_manifest/0`).
  """
  @spec enabled?() :: boolean()
  def enabled?, do: configured_enabled?() and match?({:ok, _}, helper_manifest())

  @doc "Whether a missing or invalid helper manifest must stop the node at boot."
  @spec require_helper_manifest?() :: boolean()
  def require_helper_manifest?, do: get(:require_helper_manifest) == true

  @doc "The secret keying credential fingerprints, or nil when unset."
  @spec fingerprint_secret() :: String.t() | nil
  def fingerprint_secret, do: get(:fingerprint_secret)

  @doc "The node-local spool root."
  @spec spool_dir() :: String.t()
  def spool_dir, do: get(:spool_dir) || Path.join(System.tmp_dir!(), "goodflows-pools")

  @doc "The directory holding `manifest.json` and the per-target helper binaries."
  @spec helper_artifact_dir() :: String.t()
  def helper_artifact_dir,
    do: get(:helper_artifact_dir) || Application.app_dir(:good_flows, "priv/gf-transfer")

  @doc "Report file cap in bytes (32 MiB)."
  @spec report_max_bytes() :: pos_integer()
  def report_max_bytes, do: @report_max_bytes

  @doc "Bytes of the `GOODFLOWS_OUTPUT` file returned with an exit (65,537)."
  @spec outputs_max_bytes() :: pos_integer()
  def outputs_max_bytes, do: @outputs_max_bytes

  @doc "Largest helper binary the bootstrap filesystem write accepts (16 MiB, inclusive)."
  @spec bootstrap_max_bytes() :: pos_integer()
  def bootstrap_max_bytes, do: @bootstrap_max_bytes

  @doc "The helper protocol version this server speaks."
  @spec protocol_version() :: pos_integer()
  def protocol_version, do: @protocol_version

  @doc "PgFlow hard timeout, in seconds, for the provision job."
  @spec provision_job_timeout_seconds() :: pos_integer()
  def provision_job_timeout_seconds, do: @provision_job_timeout_seconds

  @doc "PgFlow hard timeout, in seconds, for the reset and destroy jobs."
  @spec member_job_timeout_seconds() :: pos_integer()
  def member_job_timeout_seconds, do: @member_job_timeout_seconds

  @doc """
  Time after an operation started by which a member job has certainly
  ended (its hard timeout plus the margin). Past it, an unreachable worker
  is treated as gone.
  """
  @spec member_operation_deadline_ms(:provision | :reset | :destroy) :: pos_integer()
  def member_operation_deadline_ms(:provision),
    do: @provision_job_timeout_seconds * 1_000 + @job_margin_ms

  def member_operation_deadline_ms(_kind),
    do: @member_job_timeout_seconds * 1_000 + @job_margin_ms

  @doc """
  Raises unless every setting is a positive integer, the transfer chunk is
  at most 1 MiB, and the member job timeouts cover their budgets; then
  loads the helper manifest. A manifest problem does not raise: it is
  logged and pools stay disabled on this node.
  """
  @spec validate!(keyword()) :: :ok
  def validate!(opts \\ []) do
    for key <- @positive_keys, do: ensure_positive!(key, get(key))

    if transfer_chunk_bytes() > @mib do
      raise ArgumentError,
            "config :good_flows, GoodFlows.Pools, transfer_chunk_bytes must be at most " <>
              "#{@mib}, got: #{transfer_chunk_bytes()}"
    end

    if spool_account_max_bytes() < workspace_max_bytes() do
      raise ArgumentError,
            "config :good_flows, GoodFlows.Pools, spool_account_max_bytes " <>
              "(#{spool_account_max_bytes()}) must be at least workspace_max_bytes " <>
              "(#{workspace_max_bytes()}), or no upload could ever be admitted"
    end

    provision_job =
      Keyword.get(opts, :provision_job_timeout_seconds, @provision_job_timeout_seconds)

    member_job = Keyword.get(opts, :member_job_timeout_seconds, @member_job_timeout_seconds)

    ensure_covers!(
      "GoodFlows.Pools.ProvisionMemberJob",
      provision_job,
      provision_timeout_ms(),
      :provision_timeout_ms
    )

    ensure_covers!(
      "GoodFlows.Pools.ResetMemberJob and DestroyMemberJob",
      member_job,
      SpryConfig.step_timeout_ms(),
      :step_timeout_ms
    )

    case load_manifest() do
      {:ok, _manifest} ->
        :ok

      {:error, reason} ->
        if configured_enabled?() and require_helper_manifest?() do
          raise ArgumentError,
                "POOLS_ENABLED is true but the gf-transfer helper manifest in " <>
                  "#{helper_artifact_dir()} is unusable (#{reason}). Run " <>
                  "sprite-transfer/scripts/package.sh before `mix release`, or set " <>
                  "POOLS_ENABLED=false."
        end

        if configured_enabled?() do
          Logger.error(
            "Sprite pools are disabled: the gf-transfer helper manifest in " <>
              "#{helper_artifact_dir()} is unusable (#{reason}). Run " <>
              "sprite-transfer/scripts/package.sh before building the release."
          )
        end

        :ok
    end
  end

  defp ensure_covers!(job, timeout_seconds, budget_ms, key) do
    if timeout_seconds * 1_000 < budget_ms + @job_margin_ms do
      raise ArgumentError,
            "#{job} timeout (#{timeout_seconds}s) must cover #{key} (#{budget_ms}ms) " <>
              "plus #{div(@job_margin_ms, 1_000)}s of margin"
    end
  end

  @doc "The helper manifest loaded at boot, or why it is unusable."
  @spec helper_manifest() :: {:ok, manifest()} | {:error, String.t()}
  def helper_manifest do
    case :persistent_term.get(@manifest_key, nil) do
      nil -> load_manifest()
      result -> result
    end
  end

  @doc """
  Reads and validates `manifest.json` from `helper_artifact_dir/0`, checking
  each listed binary's size (at most #{@bootstrap_max_bytes} bytes) and
  SHA-256, and caches the result for `helper_manifest/0`.
  """
  @spec load_manifest() :: {:ok, manifest()} | {:error, String.t()}
  def load_manifest do
    result = read_manifest(helper_artifact_dir())
    :persistent_term.put(@manifest_key, result)
    result
  end

  @doc "The packaged helper artifact for a `uname -m` value."
  @spec helper_artifact(String.t()) ::
          {:ok, artifact()} | {:error, :unsupported_architecture | :helper_unavailable}
  def helper_artifact(arch) when is_binary(arch) do
    case helper_manifest() do
      {:ok, %{artifacts: artifacts}} ->
        case Enum.find(artifacts, &(&1.arch == String.trim(arch))) do
          nil -> {:error, :unsupported_architecture}
          artifact -> {:ok, artifact}
        end

      {:error, _reason} ->
        {:error, :helper_unavailable}
    end
  end

  @doc """
  The helper identity recorded on members: `"<version>+p<protocol>"` from
  the packaged manifest, or `nil` without a manifest.

  It deliberately excludes the binaries' SHA-256: builds are not
  reproducible, so a rebuild of the same release (another host, toolchain,
  or a rollback) would otherwise make every member stale. The installed
  binary's SHA-256 is still verified against the manifest entry for the
  member's architecture when it is provisioned. See `helper_stale?/1`.
  """
  @spec helper_version() :: String.t() | nil
  def helper_version do
    case helper_manifest() do
      {:ok, manifest} -> helper_version(manifest)
      {:error, _reason} -> nil
    end
  end

  @doc """
  The helper identity for an already-loaded `manifest`, in the same format
  as `helper_version/0`. Used when the manifest is in hand, such as while
  provisioning a member.
  """
  @spec helper_version(manifest()) :: String.t()
  def helper_version(%{version: version, protocol: protocol}), do: "#{version}+p#{protocol}"

  @doc """
  Whether a member's recorded helper identity is older than this node's
  packaged helper: a lower protocol, or the same protocol and a lower
  release version (SemVer order; an unparsable version is compared for
  equality instead). A member with a newer helper is never stale here, so
  during a rolling deploy (or a rollback) old and new nodes do not retire
  each other's members back and forth; the newest generation wins once
  every node runs it. Never stale when this node has no manifest (pools are
  disabled then) or when the member has no recorded helper yet.
  """
  @spec helper_stale?(String.t() | nil) :: boolean()
  def helper_stale?(nil), do: false

  def helper_stale?(member_version) when is_binary(member_version) do
    case helper_version() do
      nil -> false
      current -> older_helper?(parse_helper(member_version), parse_helper(current))
    end
  end

  @doc """
  Whether this node speaks the helper protocol of a member's recorded
  helper identity. A member built by a newer node with another protocol is
  kept (not stale) but never granted here.
  """
  @spec helper_compatible?(String.t() | nil) :: boolean()
  def helper_compatible?(member_version) when is_binary(member_version),
    do: elem(parse_helper(member_version), 1) == @protocol_version

  def helper_compatible?(nil), do: false

  # `"<version>+p<protocol>[+<legacy digest>]"` -> {version, protocol}.
  defp parse_helper(identity) do
    case String.split(identity, "+") do
      [version, "p" <> protocol | _rest] ->
        case Integer.parse(protocol) do
          {protocol, ""} -> {version, protocol}
          _other -> {version, nil}
        end

      _other ->
        {identity, nil}
    end
  end

  defp older_helper?({_version, nil}, _current), do: true

  defp older_helper?({version, protocol}, {current_version, current_protocol}) do
    if protocol != current_protocol,
      do: protocol < current_protocol,
      else: older_version?(version, current_version)
  end

  defp older_version?(version, current) do
    with {:ok, version} <- Version.parse(version),
         {:ok, current} <- Version.parse(current) do
      Version.compare(version, current) == :lt
    else
      :error -> version != current
    end
  end

  defp read_manifest(dir) do
    with {:ok, json} <- read_file(Path.join(dir, "manifest.json")),
         {:ok, map} <- decode(json),
         {:ok, manifest} <- parse_manifest(map),
         :ok <- verify_artifacts(dir, manifest.artifacts) do
      {:ok, manifest}
    end
  end

  # The path is the packaged helper artifact dir's manifest.json, never user input.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_file(path) do
    case File.read(path) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, "cannot read manifest.json (#{:file.format_error(reason)})"}
    end
  end

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, %{} = map} -> {:ok, map}
      _other -> {:error, "manifest.json is not a JSON object"}
    end
  end

  defp parse_manifest(%{"version" => version, "protocol" => protocol, "artifacts" => artifacts})
       when is_binary(version) and is_list(artifacts) and artifacts != [] do
    with :ok <- check_protocol(protocol),
         {:ok, artifacts} <- parse_artifacts(artifacts) do
      {:ok, %{version: version, protocol: protocol, artifacts: artifacts}}
    end
  end

  defp parse_manifest(_map), do: {:error, "manifest.json lacks version, protocol, or artifacts"}

  defp check_protocol(@protocol_version), do: :ok

  defp check_protocol(protocol),
    do: {:error, "helper protocol #{inspect(protocol)} is not #{@protocol_version}"}

  defp parse_artifacts(artifacts) do
    Enum.reduce_while(artifacts, {:ok, []}, fn
      %{"target" => target, "arch" => arch, "path" => path, "sha256" => sha, "size" => size},
      {:ok, acc}
      when is_binary(target) and is_binary(arch) and is_binary(path) and is_binary(sha) and
             is_integer(size) ->
        artifact = %{
          target: target,
          arch: arch,
          path: path,
          sha256: String.downcase(sha),
          size: size
        }

        {:cont, {:ok, acc ++ [artifact]}}

      _other, _acc ->
        {:halt, {:error, "manifest.json has an invalid artifact entry"}}
    end)
  end

  defp verify_artifacts(dir, artifacts) do
    Enum.reduce_while(artifacts, :ok, fn artifact, :ok ->
      case verify_artifact(dir, artifact) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, "#{artifact.target}: #{reason}"}}
      end
    end)
  end

  defp verify_artifact(dir, %{path: path, size: size, sha256: sha}) do
    full = Path.expand(path, dir)

    cond do
      not String.starts_with?(full, Path.expand(dir) <> "/") ->
        {:error, "artifact path escapes the artifact directory"}

      size > @bootstrap_max_bytes ->
        {:error, "artifact is larger than the #{@bootstrap_max_bytes}-byte bootstrap limit"}

      true ->
        verify_bytes(full, size, sha)
    end
  end

  defp verify_bytes(path, size, sha) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: ^size}} ->
        if file_sha256(path) == sha, do: :ok, else: {:error, "SHA-256 mismatch"}

      {:ok, %File.Stat{type: :regular}} ->
        {:error, "size mismatch"}

      {:ok, _stat} ->
        {:error, "artifact is not a regular file"}

      {:error, reason} ->
        {:error, "missing binary (#{:file.format_error(reason)})"}
    end
  end

  @doc """
  The lowercase hex SHA-256 of the file at `path`, streamed in 64 KiB
  chunks. Used to verify packaged helper artifacts and reassembled
  transfer parts.
  """
  @spec file_sha256(String.t()) :: String.t()
  # Paths are server-controlled: packaged helper artifacts and spool files named by UUID/sha256.
  # sobelow_skip ["Traversal.FileModule"]
  def file_sha256(path) do
    path
    |> File.stream!(65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp ensure_positive!(key, value) do
    unless is_integer(value) and value > 0 do
      raise ArgumentError,
            "config :good_flows, GoodFlows.Pools, #{key} must be a positive integer, " <>
              "got: #{inspect(value)}"
    end
  end

  defp get(key) do
    :good_flows
    |> Application.get_env(GoodFlows.Pools, [])
    |> Keyword.get(key, Keyword.fetch!(@defaults, key))
  end
end
