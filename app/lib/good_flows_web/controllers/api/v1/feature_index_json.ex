defmodule GoodFlowsWeb.Api.V1.FeatureIndexJSON do
  @moduledoc """
  Renders feature index versions. Public and private keys see the same
  fields.
  """

  alias GoodFlows.FeatureIndex.Version

  @doc "Renders a sync result; `duplicate` is true when it matched the newest version."
  def sync(%{version: %Version{} = version, duplicate: duplicate}) do
    %{data: Map.put(data(version), :duplicate, duplicate)}
  end

  @doc "Renders one version."
  def show(%{version: %Version{} = version}), do: %{data: data(version)}

  @doc "Renders one page of version summaries."
  def index(%{versions: versions, next_cursor: next_cursor}) do
    %{
      data:
        Enum.map(versions, fn v ->
          %{
            version: v.version,
            inserted_at: DateTime.to_iso8601(v.inserted_at),
            feature_count: length(v.features)
          }
        end),
      next_cursor: next_cursor
    }
  end

  defp data(%Version{} = version) do
    %{
      version: version.version,
      inserted_at: DateTime.to_iso8601(version.inserted_at),
      features: version.features
    }
  end
end
