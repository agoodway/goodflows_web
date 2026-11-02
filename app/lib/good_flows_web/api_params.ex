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

  @doc "The `:project` and recipe `:id` path parameters."
  @spec recipe() :: keyword()
  def recipe do
    project() ++ [id: [in: :path, type: :string, description: "Recipe ID", required: true]]
  end

  @doc "The `:project` and `:pool` (pool slug) path parameters."
  @spec pool() :: keyword()
  def pool do
    project() ++ [pool: [in: :path, type: :string, description: "Pool slug", required: true]]
  end

  @doc "The `503` response for pool routes while pools are disabled on the server."
  @spec pools_disabled() :: {String.t(), String.t(), module()}
  def pools_disabled do
    {"Sprite pools are disabled on this server", "application/json", ErrorResponse}
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
end
