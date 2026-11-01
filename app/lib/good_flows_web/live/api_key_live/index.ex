defmodule GoodFlowsWeb.ApiKeyLive.Index do
  @moduledoc """
  Lists, creates, and revokes the current user's API keys for the current
  account. A new key's raw token is shown exactly once, right after creation.
  """
  use GoodFlowsWeb, :live_view

  alias GoodFlows.Accounts
  alias GoodFlows.Accounts.ApiKey

  @impl true
  def mount(_params, _session, socket) do
    %{current_scope: scope, current_account: account} = socket.assigns
    account_user = Accounts.get_account_user(scope.user, account)
    api_keys = Accounts.list_api_keys(account_user)

    {:ok,
     socket
     |> assign(
       page_title: "API Keys",
       active_nav: :api_keys,
       breadcrumbs: [
         %{label: "Dashboard", to: ~p"/dashboard/accounts/#{account.id}"},
         %{label: "API Keys"}
       ],
       account_user: account_user,
       keys_empty?: api_keys == [],
       show_create_modal: false,
       raw_token: nil,
       revoke_key: nil
     )
     |> assign_form(Accounts.change_api_key(%ApiKey{}))
     |> stream(:api_keys, api_keys)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-end justify-between gap-4">
        <div>
          <h1 class="text-xl font-bold tracking-tight text-base-content">API Keys</h1>
          <p class="mt-0.5 text-sm text-base-content/50">
            Keys authenticate API requests as you, within {@current_account.name}.
          </p>
        </div>
        <.button :if={!@keys_empty?} id="new-key-btn" variant="primary" phx-click="show_create_modal">
          <.icon name="hero-plus" class="size-4" /> Create key
        </.button>
      </div>

      <.empty_state :if={@keys_empty?} />

      <div
        :if={!@keys_empty?}
        class="responsive-table rounded-xl border border-base-300/60 bg-base-100"
      >
        <table class="w-full text-sm">
          <thead>
            <tr>
              <th class="text-left">Name</th>
              <th class="text-left">Type</th>
              <th class="text-left">Prefix</th>
              <th class="text-left">Status</th>
              <th class="text-left">Last used</th>
              <th class="text-left">Created</th>
              <th><span class="sr-only">Actions</span></th>
            </tr>
          </thead>
          <tbody id="api-keys" phx-update="stream">
            <tr :for={{dom_id, key} <- @streams.api_keys} id={dom_id}>
              <td data-label="Name" class="font-medium">{key.name}</td>
              <td data-label="Type"><.type_badge type={key.type} /></td>
              <td data-label="Prefix">
                <code class="rounded bg-base-200 px-1.5 py-0.5 text-xs">{key.token_prefix}…</code>
              </td>
              <td data-label="Status"><.status_badge key={key} /></td>
              <td data-label="Last used" class="text-base-content/50">
                {format_datetime(key.last_used_at) || "Never"}
              </td>
              <td data-label="Created" class="text-base-content/50">
                {format_datetime(key.inserted_at)}
              </td>
              <td data-label="" class="table-actions">
                <button
                  :if={key.status == :active}
                  id={"revoke-#{key.id}"}
                  type="button"
                  phx-click="confirm_revoke"
                  phx-value-id={key.id}
                  class="btn btn-ghost btn-xs text-error"
                >
                  Revoke
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>

    <.create_key_modal :if={@show_create_modal} form={@form} />
    <.token_display_modal :if={@raw_token} raw_token={@raw_token} />
    <.revoke_confirm_modal :if={@revoke_key} key={@revoke_key} />
    """
  end

  defp empty_state(assigns) do
    ~H"""
    <div
      id="api-keys-empty"
      class="rounded-xl border border-dashed border-base-300 bg-base-100 p-12 text-center"
    >
      <div class="mx-auto flex size-12 items-center justify-center rounded-full bg-primary/10">
        <.icon name="hero-key" class="size-6 text-primary" />
      </div>
      <h3 class="mt-4 text-sm font-semibold text-base-content">No API keys yet</h3>
      <p class="mt-1 text-sm text-base-content/50">
        Create a key to start calling the API from scripts and services.
      </p>
      <.button id="empty-new-key-btn" variant="primary" class="mt-5" phx-click="show_create_modal">
        <.icon name="hero-plus" class="size-4" /> Create key
      </.button>
    </div>
    """
  end

  attr :type, :atom, required: true

  defp type_badge(assigns) do
    ~H"""
    <span class={["badge badge-sm badge-soft", type_badge_class(@type)]}>
      {if @type == :private, do: "Private · read-write", else: "Public · read-only"}
    </span>
    """
  end

  attr :key, ApiKey, required: true

  defp status_badge(assigns) do
    assigns = assign(assigns, :status, key_status(assigns.key))

    ~H"""
    <span class={["badge badge-sm badge-soft", status_badge_class(@status)]}>
      {@status |> Atom.to_string() |> String.capitalize()}
    </span>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true

  defp create_key_modal(assigns) do
    ~H"""
    <dialog
      id="create-key-modal"
      class="modal modal-open"
      phx-window-keydown="hide_create_modal"
      phx-key="Escape"
    >
      <div class="modal-box">
        <h3 class="text-lg font-bold">Create API key</h3>
        <.form
          for={@form}
          id="create-key-form"
          phx-change="validate"
          phx-submit="create_key"
          class="mt-4"
        >
          <.input field={@form[:name]} type="text" label="Name" placeholder="e.g. Production worker" />
          <.input
            field={@form[:type]}
            type="select"
            label="Type"
            options={[{"Public (read-only)", :public}, {"Private (read-write)", :private}]}
          />
          <.input field={@form[:expires_at]} type="datetime-local" label="Expires at (UTC, optional)" />
          <div class="modal-action">
            <button type="button" class="btn btn-ghost" phx-click="hide_create_modal">Cancel</button>
            <.button type="submit" variant="primary" phx-disable-with="Creating…">
              Create key
            </.button>
          </div>
        </.form>
      </div>
      <div class="modal-backdrop" phx-click="hide_create_modal"></div>
    </dialog>
    """
  end

  attr :raw_token, :string, required: true

  defp token_display_modal(assigns) do
    ~H"""
    <dialog
      id="token-display-modal"
      class="modal modal-open"
      phx-window-keydown="dismiss_token"
      phx-key="Escape"
    >
      <div class="modal-box">
        <h3 class="text-lg font-bold">Your new API key</h3>
        <div role="alert" class="alert alert-warning alert-soft mt-3">
          <.icon name="hero-exclamation-triangle" class="size-5" />
          <span class="text-sm">Copy it now. You won't be able to see it again.</span>
        </div>
        <div class="mt-4 flex items-center gap-2">
          <input
            id="token-value"
            type="text"
            value={@raw_token}
            readonly
            class="input w-full font-mono text-sm"
          />
          <button
            id="copy-token-btn"
            type="button"
            phx-hook=".CopyToClipboard"
            phx-update="ignore"
            data-copy-target="#token-value"
            class="btn btn-square btn-ghost transition-colors"
            aria-label="Copy API key"
          >
            <.icon name="hero-clipboard-document" class="size-5" />
          </button>
        </div>
        <div class="modal-action">
          <button
            id="dismiss-token-btn"
            type="button"
            class="btn btn-primary"
            phx-click="dismiss_token"
          >
            Done
          </button>
        </div>
      </div>
    </dialog>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyToClipboard">
      export default {
        mounted() {
          this.el.addEventListener("click", () => {
            const target = document.querySelector(this.el.dataset.copyTarget);
            if (!target) return;
            const flash = (cls) => {
              this.el.classList.add(cls);
              setTimeout(() => this.el.classList.remove(cls), 2000);
            };
            navigator.clipboard.writeText(target.value)
              .then(() => flash("text-success"))
              .catch(() => flash("text-error"));
          });
        }
      }
    </script>
    """
  end

  attr :key, ApiKey, required: true

  defp revoke_confirm_modal(assigns) do
    ~H"""
    <dialog
      id="revoke-confirm-modal"
      class="modal modal-open"
      phx-window-keydown="cancel_revoke"
      phx-key="Escape"
    >
      <div class="modal-box">
        <h3 class="text-lg font-bold">Revoke “{@key.name}”?</h3>
        <p class="mt-2 text-sm text-base-content/70">
          Anything using this key loses access immediately. This can't be undone.
        </p>
        <div class="modal-action">
          <button type="button" class="btn btn-ghost" phx-click="cancel_revoke">Cancel</button>
          <button id="confirm-revoke-btn" type="button" class="btn btn-error" phx-click="revoke_key">
            Revoke key
          </button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="cancel_revoke"></div>
    </dialog>
    """
  end

  @impl true
  def handle_event("show_create_modal", _params, socket) do
    {:noreply, assign(socket, show_create_modal: true)}
  end

  def handle_event("hide_create_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(show_create_modal: false)
     |> assign_form(Accounts.change_api_key(%ApiKey{}))}
  end

  def handle_event("validate", %{"api_key" => params}, socket) do
    changeset = Accounts.change_api_key(%ApiKey{}, params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("create_key", %{"api_key" => params}, socket) do
    case Accounts.create_api_key(socket.assigns.account_user, params) do
      {:ok, {api_key, token}} ->
        {:noreply,
         socket
         |> assign(show_create_modal: false, raw_token: token, keys_empty?: false)
         |> assign_form(Accounts.change_api_key(%ApiKey{}))
         |> stream_insert(:api_keys, api_key, at: 0)}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("dismiss_token", _params, socket) do
    {:noreply, assign(socket, raw_token: nil)}
  end

  def handle_event("confirm_revoke", %{"id" => id}, socket) do
    {:noreply, assign(socket, revoke_key: Accounts.get_api_key(socket.assigns.account_user, id))}
  end

  def handle_event("cancel_revoke", _params, socket) do
    {:noreply, assign(socket, revoke_key: nil)}
  end

  def handle_event("revoke_key", _params, %{assigns: %{revoke_key: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("revoke_key", _params, socket) do
    case Accounts.revoke_api_key(socket.assigns.revoke_key) do
      {:ok, api_key} ->
        {:noreply,
         socket
         |> assign(revoke_key: nil)
         |> stream_insert(:api_keys, api_key)
         |> put_flash(:info, "API key revoked.")}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> assign(revoke_key: nil)
         |> put_flash(:error, "Could not revoke the API key.")}
    end
  end

  defp assign_form(socket, changeset), do: assign(socket, :form, to_form(changeset))

  defp key_status(%ApiKey{status: :revoked}), do: :revoked

  defp key_status(%ApiKey{expires_at: %DateTime{} = expires_at}) do
    if DateTime.after?(DateTime.utc_now(), expires_at), do: :expired, else: :active
  end

  defp key_status(%ApiKey{}), do: :active

  defp type_badge_class(:private), do: "badge-warning"
  defp type_badge_class(:public), do: "badge-info"

  defp status_badge_class(:active), do: "badge-success"
  defp status_badge_class(:expired), do: "badge-neutral"
  defp status_badge_class(:revoked), do: "badge-error"

  defp format_datetime(nil), do: nil
  defp format_datetime(datetime), do: Calendar.strftime(datetime, "%b %d, %Y %H:%M")
end
