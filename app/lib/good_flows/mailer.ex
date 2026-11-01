defmodule GoodFlows.Mailer do
  @moduledoc "Swoosh mailer; the adapter is configured per environment."
  use Swoosh.Mailer, otp_app: :good_flows
end
