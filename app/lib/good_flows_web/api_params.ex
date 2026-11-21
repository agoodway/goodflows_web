defmodule GoodFlowsWeb.ApiParams do
  @moduledoc """
  OpenAPI parameter and response specs shared by the `/api/v1` controllers.

  These are plain functions so controllers can call them from module
  attributes, which `OpenApiSpex.ControllerSpecs.operation/2` reads at
  compile time.
  """

  alias GoodFlows.Projects.Project
  alias GoodFlowsWeb.Schemas.ErrorResponse

  @doc "The `:project` path parameter (a project slug)."
  @spec project() :: keyword()
  def project do
    [
      project: [
        in: :path,
        type: :string,
        description: "Project slug: #{Project.slug_rule()}. Other values are `422`.",
        required: true
      ]
    ]
  end

  @doc "The `limit` (1 to 200, default 50) and `cursor` query parameters of a version list."
  @spec version_page() :: keyword()
  def version_page do
    [
      limit: [
        in: :query,
        schema: %OpenApiSpex.Schema{type: :integer, minimum: 1, maximum: 200, default: 50},
        required: false
      ],
      cursor: [in: :query, type: :string, description: "`next_cursor`", required: false]
    ]
  end

  @doc "The `:project` and recipe `:id` path parameters."
  @spec recipe() :: keyword()
  def recipe do
    project() ++ [id: [in: :path, type: :string, description: "Recipe ID", required: true]]
  end

  @doc "The `404` response for a route scoped to a project's recipe."
  @spec recipe_not_found() :: {String.t(), String.t(), module()}
  def recipe_not_found do
    {"No such project in this account, or no such recipe in this project", "application/json",
     ErrorResponse}
  end

  @doc "The `415` response for a write whose body the endpoint could not parse."
  @spec unsupported_media_type() :: {String.t(), String.t(), module()}
  def unsupported_media_type do
    {"Body is not `application/json` (or another parseable type)", "application/json",
     ErrorResponse}
  end

  @doc "The `:project` and cache `:key` path parameters."
  @spec cache_key() :: keyword()
  def cache_key do
    project() ++
      [
        key: [
          in: :path,
          type: :string,
          description: "64 lowercase hex characters. Any other value is `404`.",
          required: true
        ]
      ]
  end

  @doc "The cache `scope` query parameter; `required` for purges."
  @spec cache_scope(boolean()) :: keyword()
  def cache_scope(required) do
    [
      scope: [
        in: :query,
        type: :string,
        description:
          "Opaque scope label, usually a branch: 1 to 256 bytes with no control " <>
            "characters, not validated as a Git ref. Any other value is `422`.",
        required: required
      ]
    ]
  end

  @doc "The `403` response of cache routes."
  @spec cache_forbidden() :: {String.t(), String.t(), module()}
  def cache_forbidden do
    {"Public keys, cache keys of another project, or a scope the key may not use",
     "application/json", ErrorResponse}
  end

  @doc "The `503` response of cache routes without a configured bucket."
  @spec cache_unavailable() :: {String.t(), String.t(), module()}
  def cache_unavailable do
    {"No cache bucket is configured, or the object store is unavailable", "application/json",
     ErrorResponse}
  end
end
