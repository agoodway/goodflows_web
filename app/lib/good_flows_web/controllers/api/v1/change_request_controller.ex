defmodule GoodFlowsWeb.Api.V1.ChangeRequestController do
  @moduledoc """
  Change requests under `/api/v1/projects/:project/change-requests`.

  Reads are on the project read pipeline (any `sk_` or `pk_` key; public
  keys get redacted views, see `GoodFlowsWeb.Api.V1.ChangeRequestJSON`).
  Writes are on the project write pipeline (`sk_` keys only, of any role).
  `ck_` keys are `403` everywhere. `GoodFlowsWeb.Plugs.LoadChangeRequest`
  resolves `:number` (`422` or `404`) before any body is read, and the
  body plugs run last: `GoodFlowsWeb.Plugs.JsonBody` for create, merge,
  parent, retarget and Git facts, `GoodFlowsWeb.Plugs.MarkdownBody` for
  claims.
  """
  use GoodFlowsWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias GoodFlows.Accounts.ApiKey
  alias GoodFlows.ChangeRequests
  alias GoodFlows.ChangeRequests.Params
  alias GoodFlows.WorkflowRuns.Validator, as: RunValidator
  alias GoodFlowsWeb.ApiParams
  alias GoodFlowsWeb.Plugs.{JsonBody, LoadChangeRequest, MarkdownBody}

  alias GoodFlowsWeb.Schemas.{
    ChangeRequestCreateRequest,
    ChangeRequestListResponse,
    ChangeRequestMergeRequest,
    ChangeRequestParentRequest,
    ChangeRequestResponse,
    ChangeRequestRetargetRequest,
    ClaimsResponse,
    CodedConflictResponse,
    ConflictResponse,
    ErrorResponse,
    GitFactsDocument,
    GitFactsResponse,
    ValidationErrorResponse,
    VerdictResponse
  }

  alias OpenApiSpex.Schema

  plug LoadChangeRequest when action not in [:index, :create]

  plug JsonBody,
       [limit: :change_request_max_body_bytes, default: 65_536]
       when action in [:create, :merged, :set_parent, :retarget]

  plug JsonBody,
       [limit: :change_request_git_facts_max_body_bytes, default: 16_777_216]
       when action in [:report_git_facts]

  plug MarkdownBody when action in [:upload_claims]

  action_fallback GoodFlowsWeb.FallbackController

  tags(["Change requests"])

  @number_param [
    number: [
      in: :path,
      type: :integer,
      description: "Change request number. Anything but a positive integer is `422`.",
      required: true
    ]
  ]

  @head_param [
    head: [
      in: :path,
      type: :string,
      description: "40 or 64 lowercase hex characters. Anything else is `422`.",
      required: true
    ]
  ]

  @unauthorized {"Missing, expired or revoked API key", "application/json", ErrorResponse}
  @not_acceptable {"`Accept` does not allow JSON", "application/json", ErrorResponse}
  @read_forbidden {"Cache keys", "application/json", ErrorResponse}
  @write_forbidden {"Public or cache keys", "application/json", ErrorResponse}
  @not_found {"No such project, or no such change request", "application/json", ErrorResponse}
  @invalid_path {"Invalid project slug or number", "application/json", ValidationErrorResponse}
  @not_active {"The change request is not `draft` or `open`, or a different document is stored",
               "application/json", ConflictResponse}
  @json_errors [
    bad_request: {"Malformed JSON or unreadable body", "application/json", ErrorResponse},
    unsupported_media_type:
      {"Not `application/json`, or a `Content-Encoding` other than `identity`",
       "application/json", ErrorResponse}
  ]

  operation(:index,
    summary: "List change requests",
    description: "`number` descending, keyset-paged. Filters are exact and combined with AND.",
    parameters:
      ApiParams.project() ++
        [
          limit: [
            in: :query,
            schema: %Schema{type: :integer, minimum: 1, maximum: 200, default: 50},
            required: false
          ],
          cursor: [in: :query, type: :string, description: "`next_cursor`", required: false],
          state: [
            in: :query,
            schema: %Schema{type: :string, enum: ~w(draft open merged closed)},
            required: false
          ],
          source_branch: [in: :query, type: :string, required: false]
        ],
    responses: [
      ok: {"One page of change requests", "application/json", ChangeRequestListResponse},
      unauthorized: @unauthorized,
      forbidden: @read_forbidden,
      not_found: {"No such project in this account", "application/json", ErrorResponse},
      not_acceptable: @not_acceptable,
      unprocessable_entity:
        {"Invalid filter, limit, cursor or project slug", "application/json",
         ValidationErrorResponse}
    ]
  )

  @doc "Lists one page of change requests."
  def index(conn, params) do
    with {:ok, page} <-
           ChangeRequests.list(
             conn.assigns.project,
             Map.take(params, ~w(limit cursor state source_branch))
           ) do
      render(conn, :index,
        change_requests: page.change_requests,
        next_cursor: page.next_cursor,
        redact?: redact?(conn)
      )
    end
  end

  operation(:create,
    summary: "Open a change request",
    description:
      "Creates a `draft` change request with the project's next number. " <>
        "`target_branch` defaults to the project's `default_branch`. Strict JSON, 64 KiB.",
    parameters: ApiParams.project(),
    request_body:
      {"Change request", "application/json", ChangeRequestCreateRequest, required: true},
    responses:
      [
        created: {"Opened", "application/json", ChangeRequestResponse},
        unauthorized: @unauthorized,
        forbidden: @write_forbidden,
        not_found: {"No such project in this account", "application/json", ErrorResponse},
        not_acceptable: @not_acceptable,
        request_entity_too_large: {"Body exceeds 64 KiB", "application/json", ErrorResponse},
        unprocessable_entity:
          {"Invalid body or project slug", "application/json", ValidationErrorResponse}
      ] ++ @json_errors
  )

  @doc "Opens a draft change request."
  def create(conn, _params) do
    %{current_account: account, project: project, current_api_key: api_key} = conn.assigns

    with {:ok, change_request} <-
           ChangeRequests.create(account, project, api_key, conn.private.json_body) do
      conn |> put_status(:created) |> render_one(change_request)
    end
  end

  operation(:show,
    summary: "Show a change request",
    description:
      "With `description` (the claims file for the current head, or null), the " <>
        "current `verdict` and the `history` of state changes, oldest first.",
    parameters: ApiParams.project() ++ @number_param,
    responses: [
      ok: {"The change request", "application/json", ChangeRequestResponse},
      unauthorized: @unauthorized,
      forbidden: @read_forbidden,
      not_found: @not_found,
      not_acceptable: @not_acceptable,
      unprocessable_entity: @invalid_path
    ]
  )

  @doc "Shows one change request."
  def show(conn, _params), do: render_one(conn, conn.assigns.change_request)

  @transition_description "A request for the current state is `200` and records nothing; " <>
                            "any other move is `409`. Any private key of the account may " <>
                            "change the state."
  @transition_responses [
    ok: {"The change request", "application/json", ChangeRequestResponse},
    unauthorized: @unauthorized,
    forbidden: @write_forbidden,
    not_found: @not_found,
    not_acceptable: @not_acceptable,
    conflict: {"The state does not allow this move", "application/json", ConflictResponse},
    unsupported_media_type: ApiParams.unsupported_media_type(),
    unprocessable_entity: @invalid_path
  ]

  operation(:ready,
    summary: "Move a draft to open",
    description: @transition_description,
    parameters: ApiParams.project() ++ @number_param,
    responses: @transition_responses
  )

  @doc "Moves a draft to open."
  def ready(conn, _params), do: transition(conn, :ready)

  operation(:draft,
    summary: "Move an open change request back to draft",
    description: @transition_description,
    parameters: ApiParams.project() ++ @number_param,
    responses: @transition_responses
  )

  @doc "Moves an open change request back to draft."
  def draft(conn, _params), do: transition(conn, :draft)

  operation(:close,
    summary: "Close a draft or open change request",
    description: @transition_description,
    parameters: ApiParams.project() ++ @number_param,
    responses: @transition_responses
  )

  @doc "Closes a draft or open change request."
  def close(conn, _params), do: transition(conn, :close)

  operation(:reopen,
    summary: "Reopen a closed change request in the state it had when closed",
    description: @transition_description,
    parameters: ApiParams.project() ++ @number_param,
    responses: @transition_responses
  )

  @doc "Reopens a closed change request."
  def reopen(conn, _params), do: transition(conn, :reopen)

  defp transition(conn, action) do
    %{change_request: change_request, current_api_key: api_key} = conn.assigns

    with {:ok, change_request} <- ChangeRequests.transition(change_request, api_key, action) do
      render_one(conn, change_request)
    end
  end

  operation(:merged,
    summary: "Report a merge",
    description: """
    Records that the client merged the change request on its Git host.
    Accepted from `draft` or `open` whatever the verdict: the verdict state,
    policy version and reasons at the head are stored in `merge`, and
    `merge.merged_without_mergeable_verdict` is true when that state is not
    `mergeable`. A held merge lease is released (`release_reason:
    "merged"`) without recomputing the verdict, and
    `merge.merged_without_lease` is true unless `lease_id` names the change
    request's active, unexpired lease. `merge.head_count` is the number of
    distinct heads with Git facts and `merge.fix_iterations` the number of
    `fast_forward` or `rewrite` head changes away from a head whose verdict
    had been `blocked` or `needs_review` (null when a Git facts row predates
    head kinds). The stored verdict is recorded as it is, not recomputed:
    after a policy write that recomputes in the background (more than the
    inline limit of active change requests, default 100), `merge.policy_version`
    can be older than the current policy until that job runs. The same report
    on a `merged` change request is `200` and changes nothing; a different
    one, or a `closed` change request, is `409`.
    """,
    parameters: ApiParams.project() ++ @number_param,
    request_body: {"Merge report", "application/json", ChangeRequestMergeRequest, required: true},
    responses:
      [
        ok: {"Merged", "application/json", ChangeRequestResponse},
        unauthorized: @unauthorized,
        forbidden: @write_forbidden,
        not_found: @not_found,
        not_acceptable: @not_acceptable,
        conflict:
          {"Closed, or merged with another commit or branch", "application/json",
           ConflictResponse},
        request_entity_too_large: {"Body exceeds 64 KiB", "application/json", ErrorResponse},
        unprocessable_entity:
          {"Invalid body, project slug or number", "application/json", ValidationErrorResponse}
      ] ++ @json_errors
  )

  @doc "Records a merge report."
  def merged(conn, _params) do
    %{change_request: change_request, current_api_key: api_key} = conn.assigns

    with {:ok, change_request} <-
           ChangeRequests.report_merge(change_request, api_key, conn.private.json_body) do
      render_one(conn, change_request)
    end
  end

  @editable_conflict {"`not_editable`: the change request is not `draft` or `open`",
                      "application/json", CodedConflictResponse}

  operation(:set_parent,
    summary: "Set the parent change request",
    description: """
    Stacks the change request on one parent: a change request of the same
    project with a lower number (else `422` on `number`), replacing any
    earlier parent. While the parent is `draft` or `open` the child's
    verdict is `pending` with `parent_not_merged`; while it is `closed`,
    with `parent_closed`. The child must be `draft` or `open`.
    """,
    parameters: ApiParams.project() ++ @number_param,
    request_body: {"Parent", "application/json", ChangeRequestParentRequest, required: true},
    responses:
      [
        ok: {"The change request", "application/json", ChangeRequestResponse},
        unauthorized: @unauthorized,
        forbidden: @write_forbidden,
        not_found: @not_found,
        not_acceptable: @not_acceptable,
        conflict: @editable_conflict,
        request_entity_too_large: {"Body exceeds 64 KiB", "application/json", ErrorResponse},
        unprocessable_entity:
          {"Invalid or unusable `number`, project slug or path number", "application/json",
           ValidationErrorResponse}
      ] ++ @json_errors
  )

  @doc "Sets the parent change request."
  def set_parent(conn, _params) do
    %{change_request: change_request, current_api_key: api_key} = conn.assigns

    with {:ok, change_request} <-
           ChangeRequests.set_parent(change_request, api_key, conn.private.json_body) do
      render_one(conn, change_request)
    end
  end

  operation(:clear_parent,
    summary: "Clear the parent change request",
    parameters: ApiParams.project() ++ @number_param,
    responses: [
      ok: {"The change request", "application/json", ChangeRequestResponse},
      unauthorized: @unauthorized,
      forbidden: @write_forbidden,
      not_found: @not_found,
      not_acceptable: @not_acceptable,
      conflict: @editable_conflict,
      unprocessable_entity: @invalid_path
    ]
  )

  @doc "Clears the parent change request."
  def clear_parent(conn, _params) do
    %{change_request: change_request, current_api_key: api_key} = conn.assigns

    with {:ok, change_request} <- ChangeRequests.clear_parent(change_request, api_key) do
      render_one(conn, change_request)
    end
  end

  operation(:retarget,
    summary: "Change the target branch",
    description: """
    Changes the `target_branch` of a `draft` or `open` change request. This
    is a record update: no Git ref and no head changes. With a parent, it is
    allowed only after the parent is `merged` (else `409`
    `parent_not_merged`) and only to the parent's target branch (else `422`
    on `target_branch`); without one, any branch. A held merge lease is
    `409` `lease_held`, and a parent link that keeps changing while the
    retarget runs (three attempts) is `409` `not_editable`. The verdict
    is recomputed: it is `pending` with
    `git_facts_missing` until Git facts for the head and the new target
    are reported, and answers at an unchanged head still count.
    """,
    parameters: ApiParams.project() ++ @number_param,
    request_body:
      {"Target branch", "application/json", ChangeRequestRetargetRequest, required: true},
    responses:
      [
        ok: {"Retargeted", "application/json", ChangeRequestResponse},
        unauthorized: @unauthorized,
        forbidden: @write_forbidden,
        not_found: @not_found,
        not_acceptable: @not_acceptable,
        conflict:
          {"`not_editable`, `parent_not_merged` or `lease_held`", "application/json",
           CodedConflictResponse},
        request_entity_too_large: {"Body exceeds 64 KiB", "application/json", ErrorResponse},
        unprocessable_entity:
          {"Invalid or disallowed `target_branch`, project slug or number", "application/json",
           ValidationErrorResponse}
      ] ++ @json_errors
  )

  @doc "Changes the target branch."
  def retarget(conn, _params) do
    %{change_request: change_request, current_api_key: api_key} = conn.assigns

    with {:ok, change_request} <-
           ChangeRequests.retarget(change_request, api_key, conn.private.json_body) do
      render_one(conn, change_request)
    end
  end

  operation(:report_git_facts,
    summary: "Report Git facts for a head",
    description: """
    Stores one immutable `git-facts/1` report per head and `target.branch`
    and makes its head current (`201`). An equal report (canonical JSON) is
    `200` and makes its head current again; a different one is `409`. Only
    `draft` and `open` change requests accept reports. At most 1,000
    commits and 10,000 files per list. Strict JSON, 16 MiB.
    """,
    parameters: ApiParams.project() ++ @number_param,
    request_body: {"Git facts", "application/json", GitFactsDocument, required: true},
    responses:
      [
        created: {"Stored", "application/json", ChangeRequestResponse},
        ok: {"Equal report", "application/json", ChangeRequestResponse},
        unauthorized: @unauthorized,
        forbidden: @write_forbidden,
        not_found: @not_found,
        not_acceptable: @not_acceptable,
        conflict: @not_active,
        request_entity_too_large: {"Body exceeds 16 MiB", "application/json", ErrorResponse},
        unprocessable_entity:
          {"Invalid document, project slug or number", "application/json",
           ValidationErrorResponse}
      ] ++ @json_errors
  )

  @doc "Stores a Git facts report."
  def report_git_facts(conn, _params) do
    %{change_request: change_request, current_api_key: api_key} = conn.assigns

    with {:ok, status, change_request} <-
           ChangeRequests.report_git_facts(change_request, api_key, conn.private.json_body) do
      conn |> put_status(status_code(status)) |> render_one(change_request)
    end
  end

  operation(:show_git_facts,
    summary: "Read the Git facts for a head",
    description:
      "The report for the change request's `target_branch`, or for `target` when given, " <>
        "with the `previous_head` and `head_kind` recorded when it was stored.",
    parameters:
      ApiParams.project() ++
        @number_param ++
        @head_param ++
        [target: [in: :query, type: :string, description: "Target branch", required: false]],
    responses: [
      ok: {"The report", "application/json", GitFactsResponse},
      unauthorized: @unauthorized,
      forbidden: @read_forbidden,
      not_found: {"Nothing stored for the head", "application/json", ErrorResponse},
      not_acceptable: @not_acceptable,
      unprocessable_entity:
        {"Invalid head, target, project slug or number", "application/json",
         ValidationErrorResponse}
    ]
  )

  @doc "Reads the Git facts for a head."
  def show_git_facts(conn, %{"head" => head} = params) do
    target = Map.get(params, "target")

    cond do
      not Params.sha?(head) ->
        invalid(conn, "head", "must be 40 or 64 lowercase hex characters")

      target != nil and not RunValidator.valid_branch?(target) ->
        invalid(conn, "target", "is invalid")

      true ->
        with {:ok, facts} <-
               ChangeRequests.get_git_facts(conn.assigns.change_request, head, target) do
          render(conn, :git_facts, git_facts: facts, redact?: redact?(conn))
        end
    end
  end

  operation(:upload_claims,
    summary: "Upload claims for the current head",
    description: """
    Stores one `change-claims/2` Markdown file per head byte for byte
    (`201`); identical bytes are `200`, a different file for the head is
    `409`. The YAML front matter is validated (anchors, aliases and tags are
    rejected) and checked against the current head and its Git facts; the
    body is never parsed. At most 1 MiB.
    """,
    parameters: ApiParams.project() ++ @number_param,
    request_body: {"Claims file", "text/markdown", %Schema{type: :string}, required: true},
    responses: [
      created: {"Stored", "application/json", ChangeRequestResponse},
      ok: {"Identical file", "application/json", ChangeRequestResponse},
      bad_request: {"Unreadable body", "application/json", ErrorResponse},
      unauthorized: @unauthorized,
      forbidden: @write_forbidden,
      not_found: @not_found,
      not_acceptable: @not_acceptable,
      conflict: @not_active,
      request_entity_too_large: {"Body exceeds 1 MiB", "application/json", ErrorResponse},
      unsupported_media_type:
        {"Not `text/markdown`, or a `Content-Encoding` other than `identity`", "application/json",
         ErrorResponse},
      unprocessable_entity:
        {"Invalid front matter, project slug or number", "application/json",
         ValidationErrorResponse}
    ]
  )

  @doc "Stores a claims file."
  def upload_claims(conn, _params) do
    %{change_request: change_request, current_api_key: api_key} = conn.assigns

    with {:ok, status, change_request} <-
           ChangeRequests.upload_claims(change_request, api_key, conn.private.markdown_body) do
      conn |> put_status(status_code(status)) |> render_one(change_request)
    end
  end

  operation(:show_claims,
    summary: "Read the claims for a head",
    parameters: ApiParams.project() ++ @number_param ++ @head_param,
    responses: [
      ok: {"The claims", "application/json", ClaimsResponse},
      unauthorized: @unauthorized,
      forbidden: @read_forbidden,
      not_found: {"Nothing stored for the head", "application/json", ErrorResponse},
      not_acceptable: @not_acceptable,
      unprocessable_entity:
        {"Invalid head, project slug or number", "application/json", ValidationErrorResponse}
    ]
  )

  @doc "Reads the claims for a head."
  def show_claims(conn, %{"head" => head}) do
    if Params.sha?(head) do
      with {:ok, claims} <- ChangeRequests.get_claims(conn.assigns.change_request, head) do
        render(conn, :claims, claims: claims, redact?: redact?(conn))
      end
    else
      invalid(conn, "head", "must be 40 or 64 lowercase hex characters")
    end
  end

  operation(:verdict,
    summary: "Read the verdict",
    description:
      "The stored verdict with its `head` and `policy_version`; act on it only while " <>
        "both are still current.",
    parameters: ApiParams.project() ++ @number_param,
    responses: [
      ok: {"The verdict", "application/json", VerdictResponse},
      unauthorized: @unauthorized,
      forbidden: @read_forbidden,
      not_found: @not_found,
      not_acceptable: @not_acceptable,
      unprocessable_entity: @invalid_path
    ]
  )

  @doc "Reads the stored verdict."
  def verdict(conn, _params) do
    case ChangeRequests.verdict(conn.assigns.change_request) do
      nil -> {:error, :not_found}
      verdict -> render(conn, :verdict, verdict: verdict, redact?: redact?(conn))
    end
  end

  defp render_one(conn, change_request),
    do: render(conn, :show, loaded: ChangeRequests.load(change_request), redact?: redact?(conn))

  defp status_code(:created), do: :created
  defp status_code(:retry), do: :ok

  defp invalid(conn, key, message) do
    conn |> put_status(:unprocessable_entity) |> json(%{errors: %{key => [message]}})
  end

  defp redact?(conn), do: not ApiKey.can_write?(conn.assigns.current_api_key)
end
