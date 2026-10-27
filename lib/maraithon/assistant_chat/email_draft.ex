defmodule Maraithon.AssistantChat.EmailDraft do
  @moduledoc "Keeps generated email editable when the provider cannot save a draft."

  def card(%{channel: "gmail", draft: draft, provider_draft: saved}, args) do
    args =
      args
      |> Map.put("provider", args["provider"] || args["google_provider"])
      |> Map.put("account", args["account"] || args["google_account_email"])

    %{
      "provider" => "gmail",
      "title" => "Email draft",
      "status" =>
        if(saved, do: "Saved in Gmail", else: "Draft in Maraithon · Not saved in Gmail"),
      "editable" => true,
      "google_provider" => Maraithon.Tools.GmailApiHelpers.provider_from_args(args),
      "recipient" => args["to"] || args["recipient"],
      "subject" => draft["subject"],
      "body" => draft["body"],
      "cc" => args["cc"],
      "bcc" => args["bcc"]
    }
  end

  def card(_, _), do: nil
end
