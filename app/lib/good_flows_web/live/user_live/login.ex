defmodule GoodFlowsWeb.UserLive.Login do
  @moduledoc "Log in with a magic link or email and password."
  use GoodFlowsWeb, :live_view

  alias GoodFlows.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-4">
        <.header>
          Log in
          <:subtitle>
            <%= if @current_scope do %>
              You need to reauthenticate to perform sensitive actions on your account.
            <% else %>
              Don't have an account? <.text_link navigate={~p"/users/register"}>Sign up</.text_link>
              for an account now.
            <% end %>
          </:subtitle>
        </.header>

        <.notice :if={local_mail_adapter?()} kind="info">
          You are running the local mail adapter. To see sent emails, visit <.text_link href="/dev/mailbox">the mailbox page</.text_link>.
        </.notice>

        <.panel title="Email link" icon="hero-envelope">
          <.form
            :let={f}
            for={@form}
            id="login_form_magic"
            action={~p"/users/log-in"}
            phx-submit="submit_magic"
          >
            <.input
              readonly={!!@current_scope}
              field={f[:email]}
              type="email"
              label="Email"
              autocomplete="username"
              spellcheck="false"
              required
              phx-mounted={JS.focus()}
            />
            <.button variant="primary" class="w-full">Log in with email</.button>
          </.form>
        </.panel>

        <.panel title="Password" icon="hero-lock-closed">
          <.form
            :let={f}
            for={@form}
            id="login_form_password"
            action={~p"/users/log-in"}
            phx-submit="submit_password"
            phx-trigger-action={@trigger_submit}
          >
            <.input
              readonly={!!@current_scope}
              field={f[:email]}
              id="login_form_password_email"
              type="email"
              label="Email"
              autocomplete="username"
              spellcheck="false"
              required
            />
            <.input
              field={@form[:password]}
              type="password"
              label="Password"
              autocomplete="current-password"
              spellcheck="false"
            />
            <.button variant="primary" class="w-full" name={@form[:remember_me].name} value="true">
              Log in and stay logged in
            </.button>
            <.button class="mt-2 w-full">Log in only this time</.button>
          </.form>
        </.panel>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")

    {:ok, assign(socket, form: form, trigger_submit: false)}
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  def handle_event("submit_magic", %{"user" => %{"email" => email}}, socket) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_login_instructions(
        user,
        &url(~p"/users/log-in/#{&1}")
      )
    end

    info =
      "If your email is in our system, you will receive instructions for logging in shortly."

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> push_navigate(to: ~p"/users/log-in")}
  end

  defp local_mail_adapter? do
    Application.get_env(:good_flows, GoodFlows.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
