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
       page_title: "API keys",
       active_nav: :api_keys,
       breadcrumbs: [
         %{label: "Dashboard", to: ~p"/dashboard/accounts/#{account.id}"},
         %{label: "API keys"}
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
    <div class="mx-auto max-w-5xl space-y-4 lg:space-y-6">
      <.header icon="hero-key">
        API keys
        <:subtitle>Keys authenticate API requests as you, within {@current_account.name}.</:subtitle>
        <:actions>
          <.button
            :if={!@keys_empty?}
            id="new-key-btn"
            variant="primary"
            size="sm"
            icon="hero-plus"
            phx-click="show_create_modal"
          >
            Create key
          </.button>
        </:actions>
      </.header>

      <.table id="api-keys" rows={@streams.api_keys} empty={@keys_empty?}>
        <:col :let={{_id, key}} label="Name" class="font-medium">{key.name}</:col>
        <:col :let={{_id, key}} label="Access">
          <.status_badge>{access_label(key.type)}</.status_badge>
        </:col>
        <:col :let={{_id, key}} label="Prefix">
          <.tag>{key.token_prefix}…</.tag>
        </:col>
        <:col :let={{_id, key}} label="Status"><.key_status_badge key={key} /></:col>
        <:col :let={{_id, key}} label="Last used" class="font-mono text-xs text-muted">
          {format_datetime(key.last_used_at) || "Never"}
        </:col>
        <:col :let={{_id, key}} label="Created" class="font-mono text-xs text-muted">
          {format_datetime(key.inserted_at)}
        </:col>
        <:action :let={{_id, key}}>
          <.button
            :if={key.status == :active}
            id={"revoke-#{key.id}"}
            type="button"
            variant="ghost"
            size="sm"
            phx-click="confirm_revoke"
            phx-value-id={key.id}
            aria-label={"Revoke #{key.name}"}
          >
            Revoke
          </.button>
        </:action>
        <:empty_state>
          <.empty_state id="api-keys-empty" icon="hero-key" title="No API keys yet">
            Create a key to call the API from scripts and services.
            <:actions>
              <.button
                id="empty-new-key-btn"
                variant="primary"
                icon="hero-plus"
                phx-click="show_create_modal"
              >
                Create key
              </.button>
            </:actions>
          </.empty_state>
        </:empty_state>
      </.table>
    </div>

    <.create_key_modal :if={@show_create_modal} form={@form} />
    <.token_display_modal :if={@raw_token} raw_token={@raw_token} />
    <.confirm_dialog
      :if={@revoke_key}
      id="revoke-confirm-modal"
      title="Revoke API key"
      confirm_label="Revoke key"
      on_confirm="revoke_key"
      on_cancel="cancel_revoke"
    >
      <p class="font-medium">Revoke “{@revoke_key.name}”?</p>
      <p class="mt-2 text-muted">
        Anything using this key loses access immediately. This can't be undone.
      </p>
    </.confirm_dialog>
    """
  end

  attr :key, ApiKey, required: true

  defp key_status_badge(assigns) do
    assigns = assign(assigns, :status, key_status(assigns.key))

    ~H"""
    <.status_badge kind={status_kind(@status)} dot>
      {@status |> Atom.to_string() |> String.capitalize()}
    </.status_badge>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true

  defp create_key_modal(assigns) do
    ~H"""
    <.editor_dialog id="create-key-modal" title="Create API key" on_cancel="hide_create_modal">
      <.form for={@form} id="create-key-form" phx-change="validate" phx-submit="create_key">
        <.input field={@form[:name]} type="text" label="Name" placeholder="Production worker" />
        <.input
          field={@form[:type]}
          type="select"
          label="Access"
          options={[{"Read only (public key)", :public}, {"Read and write (private key)", :private}]}
        />
        <.input field={@form[:expires_at]} type="datetime-local" label="Expires at (UTC, optional)" />
        <.dialog_actions>
          <.button type="button" variant="ghost" phx-click="hide_create_modal">Cancel</.button>
          <.button type="submit" variant="primary" phx-disable-with="Creating…">
            Create key
          </.button>
        </.dialog_actions>
      </.form>
    </.editor_dialog>
    """
  end

  attr :raw_token, :string, required: true

  defp token_display_modal(assigns) do
    ~H"""
    <.editor_dialog id="token-display-modal" title="Your new API key" on_cancel="dismiss_token">
      <.notice kind="warning">Copy the key now. It is not shown again.</.notice>
      <div class="mt-4 flex items-center gap-2">
        <label for="token-value" class="sr-only">API key</label>
        <input
          id="token-value"
          type="text"
          value={@raw_token}
          readonly
          class="ui-input font-mono text-xs"
        />
        <.button
          id="copy-token-btn"
          type="button"
          class="h-10"
          icon="hero-clipboard-document"
          phx-hook=".CopyToClipboard"
          phx-update="ignore"
          data-copy-target="#token-value"
          aria-label="Copy API key"
        >
          <span data-copy-label>Copy</span>
        </.button>
      </div>
      <.dialog_actions>
        <.button id="dismiss-token-btn" type="button" variant="primary" phx-click="dismiss_token">
          Done
        </.button>
      </.dialog_actions>
    </.editor_dialog>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyToClipboard">
      export default {
        mounted() {
          this.el.addEventListener("click", () => {
            const target = document.querySelector(this.el.dataset.copyTarget);
            if (!target) return;
            const label = this.el.querySelector("[data-copy-label]");
            const flash = (text) => {
              label.textContent = text;
              setTimeout(() => { label.textContent = "Copy"; }, 2000);
            };
            navigator.clipboard.writeText(target.value)
              .then(() => flash("Copied"))
              .catch(() => flash("Copy failed"));
          });
        }
      }
    </script>
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

  defp status_kind(:active), do: "primary"
  defp status_kind(:expired), do: "neutral"
  defp status_kind(:revoked), do: "error"

  defp access_label(:private), do: "Read and write"
  defp access_label(:public), do: "Read only"

  defp format_datetime(nil), do: nil
  defp format_datetime(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
end
