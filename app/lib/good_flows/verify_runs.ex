defmodule GoodFlows.VerifyRuns do
  @moduledoc """
  Verify runs (the `verify-runs` capability): `verify-run/1` documents of
  a project, each the record of an agent grading one commit against one
  stored scenario set, with artifacts in object storage.

  `ingest/4` validates a document (`GoodFlows.VerifyRuns.Document`), checks
  that its `scenario_set` digest is a stored set of the project with that
  source and that `results` holds exactly that set's scenario IDs, and
  stores it once per project and `run_id`: an equal document (canonical
  JSON digest) is a duplicate, a different one `:verify_run_conflict`. A
  run without artifacts is `final` at once. A run with artifacts is
  `uploading`, gets one presigned PUT per artifact (size, content type and
  SHA-256 signed in, like cache uploads), and becomes `final` on
  `commit/3` once every object is in the store with the declared length
  and SHA-256. An `uploading` run expires after the cache reservation TTL;
  `GoodFlows.VerifyRuns.Sweep` deletes it.

  A run becoming `final` recomputes, in the same transaction, the verdict
  of every `draft` or `open` change request of the project with a set
  version of its digest, and records a `verify_run_stored` event for
  each. Presigned URLs are credentials and are never logged.
  """
  import Ecto.Query

  alias GoodFlows.Accounts.{Account, ApiKey}
  alias GoodFlows.Caches
  alias GoodFlows.Caches.ObjectStore
  alias GoodFlows.ChangeRequests
  alias GoodFlows.DocumentErrors
  alias GoodFlows.JsonDocument
  alias GoodFlows.Projects.Project
  alias GoodFlows.Repo
  alias GoodFlows.ScenarioSets
  alias GoodFlows.ScenarioSets.Document, as: SetDocument
  alias GoodFlows.ScenarioSets.Version
  alias GoodFlows.VerifyRuns.{Artifact, Document, Run}
  alias GoodFlows.WorkflowRuns.Validator, as: RunValidator

  @default_page_size 50
  @max_page_size 200

  @typedoc "A presigned artifact upload."
  @type upload :: %{
          artifact_id: String.t(),
          upload_url: String.t(),
          upload_headers: ObjectStore.upload_headers(),
          upload_url_expires_at: DateTime.t()
        }

  @typedoc "The result of an upload."
  @type ingested :: %{run: Run.t(), duplicate: boolean(), uploads: [upload()]}

  @doc """
  Stores a verify run from a normalized body. Errors: `{:invalid_body,
  errors}`, `:artifact_too_large`, `:object_store_unconfigured` (a run
  with artifacts and no bucket), `:verify_run_conflict` or `:not_found`.
  """
  @spec ingest(Account.t(), Project.t(), ApiKey.t(), term()) ::
          {:ok, ingested()}
          | {:error,
             :not_found
             | :artifact_too_large
             | :object_store_unconfigured
             | :verify_run_conflict
             | {:invalid_body, DocumentErrors.errors()}}
  def ingest(%Account{id: account_id}, %Project{account_id: account_id} = project, api_key, body) do
    with {:ok, document, columns} <- Document.validate(body),
         :ok <- check_storage(document),
         :ok <- check_set(project, document) do
      Repo.transaction(fn -> ingest_locked(project, api_key, document, columns) end)
    end
  end

  def ingest(%Account{}, %Project{}, _api_key, _body), do: {:error, :not_found}

  defp check_storage(%{"artifacts" => []}), do: :ok

  defp check_storage(_document),
    do: if(ObjectStore.configured?(), do: :ok, else: {:error, :object_store_unconfigured})

  defp check_set(project, document) do
    %{"digest" => digest, "source" => source} = document["scenario_set"]

    version =
      Repo.one(
        from v in Version,
          where: v.project_id == ^project.id and v.source == ^source and v.digest == ^digest,
          limit: 1
      )

    cond do
      version == nil ->
        invalid(%{"scenario_set.digest" => ["must be the digest of a stored scenario set"]})

      Enum.sort(Enum.map(document["results"], &SetDocument.id_string(&1["id"]))) !=
          Enum.sort(Enum.map(Version.scenarios(version), & &1.id)) ->
        invalid(%{"results" => ["must have one result for each scenario of the set"]})

      true ->
        :ok
    end
  end

  defp invalid(errors), do: {:error, {:invalid_body, errors}}

  defp ingest_locked(project, api_key, document, columns) do
    ScenarioSets.lock_digest(project.id, columns.scenario_set_digest)
    lock_run(project.id, columns.run_id)
    digest = JsonDocument.digest(document)
    now = DateTime.utc_now()

    case Repo.get_by(Run, project_id: project.id, run_id: columns.run_id) do
      nil ->
        insert(project, api_key, document, columns, digest)

      %Run{status: "uploading", expires_at: expires_at} = stale ->
        cond do
          not DateTime.after?(expires_at, now) ->
            Repo.delete!(stale)
            insert(project, api_key, document, columns, digest)

          stale.digest == digest ->
            stale = Repo.preload(stale, :artifacts)
            %{run: stale, duplicate: true, uploads: presign(stale.artifacts)}

          true ->
            Repo.rollback(:verify_run_conflict)
        end

      %Run{digest: ^digest} = run ->
        %{run: run, duplicate: true, uploads: []}

      %Run{} ->
        Repo.rollback(:verify_run_conflict)
    end
  end

  defp lock_run(project_id, run_id) do
    Repo.query!(
      "SELECT pg_advisory_xact_lock(hashtextextended('verify_run:' || $1 || ':' || $2, 0))",
      [project_id, run_id],
      log: false
    )
  end

  defp insert(project, api_key, document, columns, digest) do
    now = DateTime.utc_now()
    final? = document["artifacts"] == []

    run =
      Repo.insert!(
        struct(
          Run,
          Map.merge(columns, %{
            account_id: project.account_id,
            project_id: project.id,
            status: if(final?, do: "final", else: "uploading"),
            document: document,
            digest: digest,
            account_user_id: api_key.account_user_id,
            api_key_id: api_key.id,
            expires_at:
              if(final?,
                do: nil,
                else: DateTime.add(now, Caches.setting(:cache_reservation_ttl_seconds), :second)
              ),
            finalized_at: if(final?, do: now)
          })
        )
      )

    artifacts =
      Enum.map(document["artifacts"], fn artifact ->
        id = Ecto.UUID.generate()

        Repo.insert!(%Artifact{
          id: id,
          verify_run_id: run.id,
          artifact_id: artifact["id"],
          object_key: Artifact.object_key(project.id, run.id, id),
          size: artifact["size"],
          sha256: artifact["sha256"],
          content_type: artifact["content_type"]
        })
      end)

    if final?, do: recompute_and_record_stored(project, run, api_key)

    %{run: %{run | artifacts: artifacts}, duplicate: false, uploads: presign(artifacts)}
  end

  # Signs each upload, then records an `upload_expires_at` no earlier than
  # the URL's expiry (the deletion queue waits for it).
  defp presign(artifacts) do
    ttl = Caches.setting(:cache_upload_url_ttl_seconds)

    uploads =
      Enum.map(artifacts, fn artifact ->
        {url, headers} =
          ObjectStore.presign_put(artifact.object_key, %{
            size: artifact.size,
            sha256: artifact.sha256,
            content_type: artifact.content_type,
            expires_in: ttl
          })

        {artifact, url, headers}
      end)

    expires_at = DateTime.add(DateTime.utc_now(), ttl, :second)
    ids = Enum.map(artifacts, & &1.id)

    if ids != [] do
      Artifact
      |> where([a], a.id in ^ids)
      |> Repo.update_all(set: [upload_expires_at: expires_at])
    end

    Enum.map(uploads, fn {artifact, url, headers} ->
      %{
        artifact_id: artifact.artifact_id,
        upload_url: url,
        upload_headers: headers,
        upload_url_expires_at: expires_at
      }
    end)
  end

  @doc """
  Makes an `uploading` run `final` once every artifact object exists with
  the declared length and SHA-256. A `final` run is returned again.
  `:not_found` when the run is not in the project, has expired, or was
  uploaded by another key; `{:invalid_body, %{"artifacts" => …}}` naming
  the missing or mismatched artifacts (the run stays `uploading`);
  `:object_store_unavailable` when the store cannot answer.
  """
  @spec commit(Project.t(), ApiKey.t(), String.t()) ::
          {:ok, Run.t()}
          | {:error,
             :not_found | :object_store_unavailable | {:invalid_body, DocumentErrors.errors()}}
  def commit(%Project{} = project, %ApiKey{id: api_key_id} = api_key, run_id) do
    with {:ok, run} <- fetch_own(project, api_key_id, run_id) do
      case run.status do
        "final" -> {:ok, run}
        "uploading" -> verify_and_finalize(project, api_key, run)
      end
    end
  end

  defp fetch_own(project, api_key_id, run_id) do
    with true <- RunValidator.canonical_uuid?(run_id),
         %Run{api_key_id: ^api_key_id} = run <-
           Repo.get_by(Run, project_id: project.id, run_id: run_id),
         true <- run.status == "final" or DateTime.after?(run.expires_at, DateTime.utc_now()) do
      {:ok, run}
    else
      _other -> {:error, :not_found}
    end
  end

  defp verify_and_finalize(project, api_key, run) do
    artifacts = Repo.all(from a in Artifact, where: a.verify_run_id == ^run.id)
    checks = Enum.map(artifacts, &{&1, check_object(&1)})

    cond do
      Enum.any?(checks, &match?({_artifact, :unavailable}, &1)) ->
        {:error, :object_store_unavailable}

      Enum.any?(checks, &match?({_artifact, :bad}, &1)) ->
        failing =
          for({artifact, :bad} <- checks, do: artifact.artifact_id) |> Enum.sort()

        invalid(%{
          "artifacts" => ["are missing or do not match: " <> Enum.join(failing, ", ")]
        })

      true ->
        finalize(project, api_key, run)
    end
  end

  defp check_object(artifact) do
    expected = artifact.sha256 |> Base.decode16!(case: :lower) |> Base.encode64()
    size = artifact.size

    case ObjectStore.head(artifact.object_key) do
      {:ok, %{size: ^size, checksum_sha256: ^expected}} -> :ok
      {:ok, _info} -> :bad
      {:error, :not_found} -> :bad
      {:error, _reason} -> :unavailable
    end
  end

  defp finalize(project, api_key, run) do
    Repo.transaction(fn ->
      ScenarioSets.lock_digest(project.id, run.scenario_set_digest)
      now = DateTime.utc_now()

      {count, _rows} =
        Run
        |> where([r], r.id == ^run.id and r.status == "uploading" and r.expires_at > ^now)
        |> Repo.update_all(set: [status: "final", finalized_at: now, expires_at: nil])

      if count == 1 do
        recompute_and_record_stored(project, run, api_key)
        %{run | status: "final", finalized_at: now, expires_at: nil}
      else
        already_final(run)
      end
    end)
  end

  defp recompute_and_record_stored(project, run, api_key) do
    data = %{
      "run_id" => run.run_id,
      "commit" => run.source_commit,
      "source" => run.scenario_set_source,
      "digest" => run.scenario_set_digest
    }

    ChangeRequests.recompute_for_scenario_digest(
      project.id,
      run.scenario_set_digest,
      {"verify_run_stored", data, api_key}
    )
  end

  defp already_final(run) do
    case Repo.get(Run, run.id) do
      %Run{status: "final"} = final -> final
      _other -> Repo.rollback(:not_found)
    end
  end

  @doc """
  One page of the project's runs, newest `finished_at` first, ties by
  `run_id` descending. Params: `"limit"` (1 to #{@max_page_size}, default
  #{@default_page_size}), `"cursor"`, and the exact filters `"commit"`,
  `"digest"` and `"status"`.
  """
  @spec list(Project.t(), map()) ::
          {:ok, %{runs: [Run.t()], next_cursor: String.t() | nil}} | {:error, Ecto.Changeset.t()}
  def list(%Project{id: project_id}, params) do
    with {:ok, filters} <- list_params(params) do
      runs =
        Run
        |> where(project_id: ^project_id)
        |> filter(:source_commit, filters.commit)
        |> filter(:scenario_set_digest, filters.digest)
        |> filter(:status, filters.status)
        |> after_cursor(filters.cursor)
        |> order_by(desc: :finished_at, desc: :run_id)
        |> limit(^(filters.limit + 1))
        |> Repo.all()

      {page, rest} = Enum.split(runs, filters.limit)
      next = if rest != [], do: encode_cursor(List.last(page))
      {:ok, %{runs: page, next_cursor: next}}
    end
  end

  defp filter(query, _field, nil), do: query
  defp filter(query, field, value), do: where(query, [r], field(r, ^field) == ^value)

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, {finished_at, run_id}) do
    where(
      query,
      [r],
      r.finished_at < ^finished_at or (r.finished_at == ^finished_at and r.run_id < ^run_id)
    )
  end

  defp list_params(params) do
    types = %{limit: :integer, cursor: :string, commit: :string, digest: :string, status: :string}

    {%{limit: @default_page_size, cursor: nil, commit: nil, digest: nil, status: nil}, types}
    |> Ecto.Changeset.cast(params, Map.keys(types), empty_values: [])
    |> Ecto.Changeset.validate_number(:limit,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: @max_page_size
    )
    |> Ecto.Changeset.validate_format(:commit, ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/)
    |> Ecto.Changeset.validate_format(:digest, ~r/\A[0-9a-f]{64}\z/)
    |> Ecto.Changeset.validate_inclusion(:status, ~w(uploading final))
    |> GoodFlows.KeysetCursor.put_cursor(&decode_cursor/1)
    |> Ecto.Changeset.apply_action(:list)
  end

  defp encode_cursor(%Run{finished_at: finished_at, run_id: run_id}) do
    Base.url_encode64("v1:#{DateTime.to_iso8601(finished_at)}|#{run_id}", padding: false)
  end

  defp decode_cursor(cursor) do
    with {:ok, "v1:" <> rest} <- Base.url_decode64(cursor, padding: false),
         [time, run_id] <- String.split(rest, "|"),
         {:ok, finished_at, 0} <- DateTime.from_iso8601(time),
         true <- RunValidator.canonical_uuid?(run_id) do
      {:ok, {finished_at, run_id}}
    else
      _other -> :error
    end
  end

  @doc "The run `run_id` of the project with its artifacts, or `:not_found`."
  @spec get(Project.t(), String.t()) :: {:ok, Run.t()} | {:error, :not_found}
  def get(%Project{id: project_id}, run_id) do
    with true <- RunValidator.canonical_uuid?(run_id),
         %Run{} = run <-
           Repo.one(
             from r in Run,
               where: r.project_id == ^project_id and r.run_id == ^run_id,
               preload: [artifacts: ^from(a in Artifact, order_by: a.artifact_id)]
           ) do
      {:ok, run}
    else
      _other -> {:error, :not_found}
    end
  end

  @doc "Presigns a download of an artifact's object."
  @spec download(Artifact.t()) :: %{url: String.t(), expires_at: DateTime.t()}
  def download(%Artifact{} = artifact) do
    ttl = Caches.setting(:cache_download_url_ttl_seconds)

    %{
      url: ObjectStore.presign_get(artifact.object_key, %{expires_in: ttl}),
      expires_at: DateTime.add(DateTime.utc_now(), ttl, :second)
    }
  end

  @doc "Counts of `passed`, `failed` and `not_run` results."
  @spec result_counts(Run.t()) :: %{String.t() => non_neg_integer()}
  def result_counts(%Run{document: document}) do
    base = %{"passed" => 0, "failed" => 0, "not_run" => 0}
    Enum.reduce(document["results"], base, &Map.update!(&2, &1["result"], fn n -> n + 1 end))
  end
end
