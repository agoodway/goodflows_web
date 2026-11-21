defmodule GoodFlows.ScenarioSets do
  @moduledoc """
  QA scenario sets of change requests (the `qa-scenario-sets`
  capability): the versioned intent and diff sets a change request is
  graded against, approvals of intent digests, and version comparison.

  `upload/3` stores the next version of the change request's intent or
  diff set from a `qa-scenarios/2` file (`GoodFlows.ScenarioSets.Document`),
  or answers `:duplicate` when its digest equals the current version's. An
  intent set's `change` must equal the change request's linked OpenSpec
  change. `decide/5` records an `approve` or `reject` decision on the
  current intent digest, under the policy's `scenarios.approver`. A digest
  is approved when its latest decision is `approve` (`approved_digests/1`),
  so the approval follows the bytes, not the head.

  Diff digests take decisions only through `diff_set_weakened` review
  answers (`record_decision/5` with source `diff`); a diff version is
  `accepted` (`accepted?/2`) when its digest's latest decision is
  `approve`, and the newest accepted diff version, else version 1, is the
  diff `baseline/2`. Storing a diff version supersedes every
  `diff_set_weakened` answer of the change request.

  Uploads and decisions are accepted only while the change request is
  `draft` or `open`. They lock the change request row and recompute its
  verdict in the same transaction.
  """
  import Ecto.Query

  alias GoodFlows.Accounts.{AccountUser, ApiKey}
  alias GoodFlows.ChangeRequests
  alias GoodFlows.ChangeRequests.ChangeRequest
  alias GoodFlows.DocumentErrors
  alias GoodFlows.ProjectEvents
  alias GoodFlows.Repo
  alias GoodFlows.Review
  alias GoodFlows.ReviewPolicies
  alias GoodFlows.ScenarioSets.{Decision, Document, Version}
  alias GoodFlows.TestReports.Shape

  @sha256 ~r/\A[0-9a-f]{64}\z/
  @max_note_bytes 10_000

  @typedoc "One version with whether its digest is approved and accepted."
  @type listed :: %{version: Version.t(), approved: boolean(), accepted: boolean()}

  @typedoc "One change of a comparison."
  @type change :: %{
          id: String.t(),
          change: String.t(),
          weakening: boolean(),
          from_priority: String.t() | nil,
          to_priority: String.t() | nil
        }

  @doc """
  Stores a set version from a normalized upload body for a `draft` or
  `open` change request. Returns `{:ok, :created, version}`, `{:ok,
  :duplicate, version}` (the current version, when the digest is equal),
  or `:not_active` or `{:invalid_body, errors}`.
  """
  @spec upload(ChangeRequest.t(), ApiKey.t(), term()) ::
          {:ok, :created | :duplicate, Version.t()}
          | {:error, :not_active | {:invalid_body, DocumentErrors.errors()}}
  def upload(%ChangeRequest{} = change_request, %ApiKey{} = api_key, body) do
    with :ok <- ChangeRequests.require_active(change_request),
         {:ok, upload} <- Document.validate(body),
         :ok <- check_change(change_request, upload) do
      Repo.transaction(fn -> upload_locked(change_request, api_key, upload) end)
      |> case do
        {:ok, {status, version}} -> {:ok, status, version}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp check_change(%ChangeRequest{openspec_change: change}, %{source: "intent"} = upload) do
    cond do
      change == nil ->
        {:error,
         {:invalid_body, %{"content.change" => ["the change request links no OpenSpec change"]}}}

      upload.front_matter["change"] != change ->
        {:error,
         {:invalid_body,
          %{"content.change" => ["must equal the change request's OpenSpec change"]}}}

      true ->
        :ok
    end
  end

  defp check_change(_change_request, _upload), do: :ok

  defp upload_locked(change_request, api_key, upload) do
    digest = Document.digest(upload.content)
    lock_digest(change_request.project_id, digest)
    change_request = ChangeRequests.lock_active(change_request)

    case current(change_request, upload.source) do
      %Version{digest: ^digest} = current ->
        {:duplicate, current}

      current ->
        version =
          Repo.insert!(
            %Version{
              change_request_id: change_request.id,
              project_id: change_request.project_id,
              source: upload.source,
              version: if(current, do: current.version + 1, else: 1),
              content: upload.content,
              digest: digest,
              front_matter: upload.front_matter,
              sections: upload.sections,
              account_user_id: api_key.account_user_id,
              api_key_id: api_key.id
            },
            log: false
          )

        if version.source == "diff", do: Review.supersede_diff_answers(change_request)
        ChangeRequests.recompute(change_request)

        ProjectEvents.record(
          change_request.project_id,
          change_request.number,
          "scenario_set_uploaded",
          %{"source" => version.source, "digest" => digest, "version" => version.version},
          api_key
        )

        {:created, version}
    end
  end

  @doc """
  Serializes a set upload with a verify run of the same project becoming
  `final` on the same digest, so one of them always recomputes with both.
  Taken before any change request row lock.
  """
  @spec lock_digest(Ecto.UUID.t(), String.t()) :: :ok
  def lock_digest(project_id, digest) do
    Repo.query!(
      "SELECT pg_advisory_xact_lock(hashtextextended('scenario_set_digest:' || $1 || ':' || $2, 0))",
      [project_id, digest],
      log: false
    )

    :ok
  end

  @doc "The current (newest) version of the change request's `source` set, or nil."
  @spec current(ChangeRequest.t(), String.t()) :: Version.t() | nil
  def current(%ChangeRequest{id: id}, source) do
    Repo.one(
      from v in Version,
        where: v.change_request_id == ^id and v.source == ^source,
        order_by: [desc: v.version],
        limit: 1
    )
  end

  @doc "Version `number` of the change request's `source` set, or `:not_found`."
  @spec get_version(ChangeRequest.t(), String.t(), pos_integer()) ::
          {:ok, Version.t()} | {:error, :not_found}
  def get_version(%ChangeRequest{id: id}, source, number) when is_integer(number) do
    case Repo.one(
           from v in Version,
             where: v.change_request_id == ^id and v.source == ^source and v.version == ^number,
             preload: :account_user
         ) do
      nil -> {:error, :not_found}
      version -> {:ok, version}
    end
  end

  @doc """
  Every version of the change request's intent and diff sets, newest
  first, each with `approved` and `accepted`.
  """
  @spec list(ChangeRequest.t()) :: %{String.t() => [listed()]}
  def list(%ChangeRequest{id: id} = change_request) do
    approved = approved_digests(change_request)

    versions =
      Repo.all(
        from v in Version,
          where: v.change_request_id == ^id,
          order_by: [asc: v.source, desc: v.version]
      )

    Map.new(Version.sources(), fn source ->
      {source,
       for(
         v <- versions,
         v.source == source,
         do: %{version: v, approved: approved?(v, approved), accepted: accepted?(v, approved)}
       )}
    end)
  end

  @doc """
  The digests of the change request whose latest decision is `approve`:
  approved intent digests and accepted diff digests. The two cannot
  collide, because `source` is part of the hashed bytes; `approved?/2`
  reads only intent versions and `accepted?/2` both.
  """
  @spec approved_digests(ChangeRequest.t()) :: MapSet.t(String.t())
  def approved_digests(%ChangeRequest{id: id}) do
    latest =
      from d in Decision,
        where: d.change_request_id == ^id,
        distinct: d.digest,
        order_by: [asc: d.digest, desc: d.id],
        select: %{digest: d.digest, decision: d.decision}

    Repo.all(from l in subquery(latest), where: l.decision == "approve", select: l.digest)
    |> MapSet.new()
  end

  @doc "Whether `version` is approved given the approved digests."
  @spec approved?(Version.t(), MapSet.t(String.t())) :: boolean()
  def approved?(%Version{source: "intent", digest: digest}, approved),
    do: MapSet.member?(approved, digest)

  def approved?(%Version{}, _approved), do: false

  @doc """
  Whether `version` is accepted given the approved digests: its digest's
  latest decision is `approve`. An intent version's `accepted` equals its
  `approved`; a diff version is accepted only through `diff_set_weakened`
  answers, and its `approved` stays false.
  """
  @spec accepted?(Version.t(), MapSet.t(String.t())) :: boolean()
  def accepted?(%Version{digest: digest}, approved), do: MapSet.member?(approved, digest)

  @doc """
  The change request's diff baseline given the approved digests: the
  newest diff version whose digest is accepted, else version 1, or nil
  when the change request has no diff set.
  """
  @spec baseline(ChangeRequest.t(), MapSet.t(String.t())) :: Version.t() | nil
  def baseline(%ChangeRequest{id: id}, approved) do
    diff = from v in Version, where: v.change_request_id == ^id and v.source == "diff"
    accepted = MapSet.to_list(approved)

    Repo.one(from v in diff, where: v.digest in ^accepted, order_by: [desc: v.version], limit: 1) ||
      Repo.one(from v in diff, where: v.version == 1)
  end

  @doc "The decisions on `digest` of the change request, oldest first, with memberships."
  @spec decisions(ChangeRequest.t() | Ecto.UUID.t(), String.t()) :: [Decision.t()]
  def decisions(%ChangeRequest{id: id}, digest), do: decisions(id, digest)

  def decisions(change_request_id, digest) do
    Repo.all(
      from d in Decision,
        where: d.change_request_id == ^change_request_id and d.digest == ^digest,
        order_by: [asc: d.id],
        preload: :account_user
    )
  end

  @doc """
  Records a decision (`:approve` or `:reject`) on the current intent
  digest from a normalized body (`digest`, and `note` for a rejection).
  The current policy's `scenarios.approver` decides who may. Returns
  `{:ok, :created, decision}`, `{:ok, :retry, decision}` when the digest's
  latest decision was made by the same membership with the same `decision`
  and `note`, or `:not_active`, `:forbidden`, `{:invalid_body, errors}` or
  `:stale_digest` (checked in that order, so a change request that is not
  live is always `:not_active`).
  """
  @spec decide(ChangeRequest.t(), AccountUser.t(), ApiKey.t(), :approve | :reject, term()) ::
          {:ok, :created | :retry, Decision.t()}
          | {:error,
             :forbidden | :not_active | :stale_digest | {:invalid_body, DocumentErrors.errors()}}
  def decide(
        %ChangeRequest{} = change_request,
        %AccountUser{} = account_user,
        api_key,
        kind,
        body
      )
      when kind in [:approve, :reject] do
    with :ok <- ChangeRequests.require_active(change_request),
         :ok <- check_approver(change_request, account_user),
         {:ok, attrs} <- decision_body(kind, body) do
      Repo.transaction(fn -> decide_locked(change_request, account_user, api_key, attrs) end)
      |> case do
        {:ok, {status, decision}} -> {:ok, status, Repo.preload(decision, :account_user)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  `:ok` when the project's current `scenarios.approver` lets `account_user`
  decide on the change request's intent set, else `{:error, :forbidden}`.
  """
  @spec check_approver(ChangeRequest.t(), AccountUser.t()) :: :ok | {:error, :forbidden}
  def check_approver(change_request, account_user) do
    approver =
      ReviewPolicies.compiled(change_request.project_id).effective["scenarios"]["approver"]

    allowed? =
      case approver do
        "any" -> true
        "other_member" -> account_user.id != change_request.opened_by_account_user_id
        "admin" -> AccountUser.admin?(account_user)
      end

    if allowed?, do: :ok, else: {:error, :forbidden}
  end

  defp decision_body(kind, body) do
    fields = %{"digest" => {:string, format: @sha256}}

    fields =
      if kind == :reject,
        do: Map.put(fields, "note", {:string, min: 1, max: @max_note_bytes, non_blank: true}),
        else: fields

    case Shape.check(body, {:object, fields}, []) do
      [] ->
        {:ok,
         %{
           decision: Atom.to_string(kind),
           digest: body["digest"],
           note: Map.get(body, "note")
         }}

      errors ->
        {:error, {:invalid_body, DocumentErrors.render(errors)}}
    end
  end

  defp decide_locked(change_request, account_user, api_key, attrs) do
    change_request = ChangeRequests.lock_active(change_request)

    case record_decision(change_request, account_user, api_key, attrs) do
      {:created, decision} ->
        ChangeRequests.recompute(change_request)
        {:created, decision}

      retry ->
        retry
    end
  end

  @doc """
  Records a decision (`attrs`: `decision`, `digest`, `note`) on the current
  digest of the change request's `source` set (`intent` by default; `diff`
  only from `diff_set_weakened` answers) for a change request the caller
  has locked (`GoodFlows.ChangeRequests.lock_active/1`), with its
  `scenario_set_approved` or `scenario_set_rejected` event carrying
  `source`, in the caller's transaction. Does not recompute the verdict. A
  decision equal to the digest's latest one by the same membership is
  `{:retry, latest}` and records nothing; a digest that is not the
  current version's of `source` rolls back with `:stale_digest`.
  """
  @spec record_decision(ChangeRequest.t(), AccountUser.t(), ApiKey.t(), map(), String.t()) ::
          {:created | :retry, Decision.t()}
  def record_decision(change_request, account_user, api_key, attrs, source \\ "intent")
      when source in ["intent", "diff"] do
    case current(change_request, source) do
      %Version{digest: digest} when digest == attrs.digest -> :ok
      _other -> Repo.rollback(:stale_digest)
    end

    latest =
      Repo.one(
        from d in Decision,
          where: d.change_request_id == ^change_request.id and d.digest == ^attrs.digest,
          order_by: [desc: d.id],
          limit: 1
      )

    if latest && latest.account_user_id == account_user.id && latest.decision == attrs.decision &&
         latest.note == attrs.note do
      {:retry, latest}
    else
      decision =
        Repo.insert!(
          %Decision{
            change_request_id: change_request.id,
            digest: attrs.digest,
            decision: attrs.decision,
            note: attrs.note,
            channel: "cli",
            account_user_id: account_user.id,
            api_key_id: api_key.id
          },
          log: false
        )

      record_decision_event(change_request, decision, source, api_key)
      {:created, decision}
    end
  end

  defp record_decision_event(change_request, %Decision{} = decision, source, api_key) do
    {type, data} =
      case decision.decision do
        "approve" ->
          {"scenario_set_approved", %{"digest" => decision.digest}}

        "reject" ->
          {"scenario_set_rejected", %{"digest" => decision.digest, "note" => decision.note}}
      end

    ProjectEvents.record(
      change_request.project_id,
      change_request.number,
      type,
      Map.put(data, "source", source),
      api_key
    )
  end

  @doc """
  Compares version `to` (default current) of the change request's
  `source` set with version `from` (default: for `intent` the newest
  approved version up to `to`, for `diff` the version before `to`). Params
  `"from"` and `"to"` are positive integers. Returns the two versions
  (`from` may be nil: everything is `added`) and the changes, or
  `:not_found` or a changeset for a bad param.
  """
  @spec compare(ChangeRequest.t(), String.t(), map()) ::
          {:ok, %{from: Version.t() | nil, to: Version.t(), changes: [change()]}}
          | {:error, :not_found | Ecto.Changeset.t()}
  def compare(%ChangeRequest{} = change_request, source, params) do
    with {:ok, params} <- compare_params(params),
         {:ok, to} <- to_version(change_request, source, params.to),
         {:ok, from} <- from_version(change_request, source, params.from, to) do
      {:ok, %{from: from, to: to, changes: changes(from, to)}}
    end
  end

  defp compare_params(params) do
    types = %{from: :integer, to: :integer}

    {%{from: nil, to: nil}, types}
    |> Ecto.Changeset.cast(params, Map.keys(types))
    |> Ecto.Changeset.validate_number(:from, greater_than_or_equal_to: 1)
    |> Ecto.Changeset.validate_number(:to, greater_than_or_equal_to: 1)
    |> Ecto.Changeset.apply_action(:compare)
  end

  defp to_version(change_request, source, nil) do
    case current(change_request, source) do
      nil -> {:error, :not_found}
      version -> {:ok, version}
    end
  end

  defp to_version(change_request, source, number), do: get_version(change_request, source, number)

  defp from_version(change_request, source, nil, to) do
    candidates =
      Repo.all(
        from v in Version,
          where:
            v.change_request_id == ^change_request.id and v.source == ^source and
              v.version <= ^to.version,
          order_by: [desc: v.version]
      )

    case source do
      "intent" ->
        approved = approved_digests(change_request)
        {:ok, Enum.find(candidates, &approved?(&1, approved))}

      "diff" ->
        {:ok, Enum.find(candidates, &(&1.version == to.version - 1))}
    end
  end

  defp from_version(change_request, source, number, _to),
    do: get_version(change_request, source, number)

  @doc """
  The changes from `from` (nil for none) to `to` by scenario ID: removed
  and demoted Musts first (`weakening`), then other removals, then
  `changed` (a new section digest or a non-weakening priority change),
  then `added`, each group ordered by ID. Only section digests and
  priorities are compared.
  """
  @spec changes(Version.t() | nil, Version.t()) :: [change()]
  def changes(from, %Version{} = to) do
    old = scenario_map(from)
    new = scenario_map(to)

    removed =
      for {id, {priority, _sha}} <- old, not Map.has_key?(new, id) do
        entry(id, "removed", priority == "must", priority, nil)
      end

    kept =
      for {id, {to_priority, to_sha}} <- new,
          {:ok, {from_priority, from_sha}} <- [Map.fetch(old, id)],
          from_priority != to_priority or from_sha != to_sha do
        if from_priority == "must" and to_priority != "must",
          do: entry(id, "demoted", true, from_priority, to_priority),
          else: entry(id, "changed", false, from_priority, to_priority)
      end

    added =
      for {id, {priority, _sha}} <- new, not Map.has_key?(old, id) do
        entry(id, "added", false, nil, priority)
      end

    all = removed ++ kept ++ added

    Enum.sort_by(all, fn change -> {group(change), change.id} end)
  end

  defp group(%{weakening: true}), do: 0
  defp group(%{change: "removed"}), do: 1
  defp group(%{change: "changed"}), do: 2
  defp group(%{change: "added"}), do: 3

  defp entry(id, change, weakening, from_priority, to_priority) do
    %{
      id: id,
      change: change,
      weakening: weakening,
      from_priority: from_priority,
      to_priority: to_priority
    }
  end

  defp scenario_map(nil), do: %{}

  defp scenario_map(%Version{} = version) do
    shas = Map.new(version.sections, &{&1["id"], &1["sha256"]})
    Map.new(Version.scenarios(version), &{&1.id, {&1.priority, Map.get(shas, &1.id)}})
  end
end
