defmodule GoodFlowsWeb.Api.V1.MergeLeaseJSON do
  @moduledoc "Renders merge leases, with the change request as its number."

  alias GoodFlows.MergeLeases.Lease

  @doc "Renders one lease."
  def show(%{lease: %Lease{} = lease, number: number}) do
    %{
      data: %{
        id: lease.id,
        change_request: number,
        target_branch: lease.target_branch,
        head: lease.head,
        base: lease.base,
        state: lease.state,
        release_reason: lease.release_reason,
        acquired_at: DateTime.to_iso8601(lease.acquired_at),
        expires_at: DateTime.to_iso8601(lease.expires_at)
      }
    }
  end
end
