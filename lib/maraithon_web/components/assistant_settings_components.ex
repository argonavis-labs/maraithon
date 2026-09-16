defmodule MaraithonWeb.AssistantSettingsComponents do
  use MaraithonWeb, :html
  attr :settings, :map, required: true

  def settings(assigns) do
    ~H"""
    <section :if={@settings.enabled} id="assistant-identity" class="space-y-4">
      <div class="flex flex-wrap items-center justify-between gap-3 border-b border-zinc-950/10 pb-2">
        <h2 class="text-base/7 font-semibold text-zinc-950">Your assistant</h2>
        <.button href={~p"/auth/google?#{%{scopes: "gmail_compose", purpose: "assistant", return_to: "/settings/assistant"}}"} variant="outline">Connect your assistant's Google account</.button>
      </div>
      <.form for={%{}} action={~p"/settings/assistant"} method="get" class="flex items-end gap-3">
        <.field label="Google account" for="assistant-account" class="min-w-0 flex-1">
          <.c_select id="assistant-account" name="assistant_account">
            <option value="">Choose an account</option>
            <option :for={account <- @settings.accounts} value={account.id} selected={account.id == @settings.selected_account}><%= account.label %></option>
          </.c_select>
        </.field>
        <.button type="submit" variant="outline">Check addresses</.button>
      </.form>
      <p :if={@settings.error} role="alert" class="text-sm/6 text-red-700"><%= @settings.error %></p>
      <.form :if={@settings.aliases != []} for={%{}} action={~p"/settings/assistant-identity"} method="post" class="space-y-3">
        <input type="hidden" name="assistant_identity[gmail_connected_account_id]" value={@settings.selected_account} />
        <div class="grid gap-3 sm:grid-cols-2">
          <.field label="Assistant name" for="assistant-name"><.c_input id="assistant-name" name="assistant_identity[display_name]" value={@settings.identity["display_name"]} required maxlength="2000" /></.field>
          <.field label="Email address" for="assistant-email">
            <.c_select id="assistant-email" name="assistant_identity[gmail_send_as_email]">
              <option :for={address <- @settings.aliases} value={address.email} selected={address.email == @settings.identity["gmail_send_as_email"]}><%= address.email %></option>
            </.c_select>
          </.field>
          <.field label="Email identity" for="assistant-mode">
            <.c_select id="assistant-mode" name="assistant_identity[gmail_mode]">
              <option value="account" selected={@settings.identity["gmail_mode"] == "account"}>Assistant's own account</option>
              <option value="alias" selected={@settings.identity["gmail_mode"] == "alias"}>Verified alias on my account</option>
            </.c_select>
          </.field>
          <.field label="Slack name" for="assistant-slack"><.c_input id="assistant-slack" name="assistant_identity[slack_username]" value={@settings.identity["slack_username"]} maxlength="2000" /></.field>
          <.field label="Slack icon URL" for="assistant-icon"><.c_input id="assistant-icon" name="assistant_identity[slack_icon_url]" value={@settings.identity["slack_icon_url"]} type="url" /></.field>
          <.field label="Signature override" for="assistant-signature"><.c_input id="assistant-signature" placeholder="Use mailbox signature" name="assistant_identity[signature_text]" value={@settings.identity["signature_text"]} maxlength="2000" /></.field>
        </div>
        <.field label="Disclosure line" for="assistant-disclosure"><.c_input id="assistant-disclosure" name="assistant_identity[disclosure_line]" value={@settings.identity["disclosure_line"] || "I'm an AI assistant handling scheduling and follow-ups."} maxlength="2000" /></.field>
        <div class="flex flex-wrap gap-5">
          <.checkbox_field label="Disclose that the assistant is AI" name="assistant_identity[disclose_ai]" checked={@settings.identity["disclose_ai"] != false} />
          <.checkbox_field label="Cc me on the first email" name="assistant_identity[cc_user_on_first_send]" checked={@settings.identity["cc_user_on_first_send"] == true} />
        </div>
        <div class="flex justify-end"><.button type="submit">Save assistant</.button></div>
      </.form>
      <.preferences preferences={@settings.preferences} calendar_accounts={@settings.calendar_accounts} />
    </section>
    """
  end

  attr :preferences, :map, required: true
  attr :calendar_accounts, :list, required: true

  defp preferences(assigns) do
    ~H"""
    <details class="border-t border-zinc-950/10 pt-3">
      <summary class="cursor-pointer text-sm/6 font-medium text-zinc-700">Scheduling and follow-up preferences</summary>
      <.form for={%{}} action={~p"/settings/delegation-preferences"} method="post" class="mt-4 space-y-4">
        <.field label="Book meetings on" for="delegation-booking-calendar">
          <.c_select id="delegation-booking-calendar" name="delegation_preferences[booking_calendar_account_id]">
            <option value="" selected={is_nil(@preferences["booking_calendar_account_id"])}>Task's Google account</option>
            <option :for={account <- @calendar_accounts} value={account.id} selected={account.id == @preferences["booking_calendar_account_id"]}><%= account.label %></option>
          </.c_select>
        </.field>
        <fieldset><legend class="text-sm/6 font-medium text-zinc-950">Also check for conflicts</legend>
          <input type="hidden" name="delegation_preferences[calendar_account_ids][]" value="" />
          <div class="mt-2 space-y-2">
            <.checkbox_field :for={account <- @calendar_accounts} label={account.label}
              name="delegation_preferences[calendar_account_ids][]" value={to_string(account.id)} unchecked_value="" checked={account.id in @preferences["calendar_account_ids"]} />
          </div>
          <p class="mt-2 text-sm/6 text-zinc-500">Checks each account's primary calendar, including the booking account.</p>
        </fieldset>
        <.field label="Timezone" for="delegation-timezone">
          <.c_select id="delegation-timezone" name="delegation_preferences[timezone]">
            <option :for={zone <- Maraithon.Timezones.options()} value={zone.value} selected={zone.value == @preferences["timezone"]}><%= zone.label %></option>
          </.c_select>
        </.field>
        <fieldset><legend class="text-sm/6 font-medium text-zinc-950">Working days</legend>
          <div class="mt-2 flex flex-wrap gap-4">
            <.checkbox_field :for={{label, day} <- Enum.with_index(~w(Mon Tue Wed Thu Fri Sat Sun), 1)} label={label}
              name="delegation_preferences[work_days][]" value={to_string(day)} unchecked_value="" checked={day in @preferences["work_days"]} />
          </div>
        </fieldset>
        <div class="grid gap-3 sm:grid-cols-2">
          <.field :for={{key, label} <- [{"work_start", "Start of day"}, {"work_end", "End of day"}]} label={label} for={"delegation-#{key}"}>
            <.c_input id={"delegation-#{key}"} name={"delegation_preferences[#{key}]"} type="time" value={@preferences[key]} required />
          </.field>
          <.field :for={{key, label, min, max} <- MaraithonWeb.AssistantSettings.numeric_preferences()} label={label} for={"delegation-#{key}"}>
            <.c_input id={"delegation-#{key}"} name={"delegation_preferences[#{key}]"} type="number" value={@preferences[key]} min={min} max={max} required />
          </.field>
          <.field label="Video link" for="delegation-video-link"><.c_input id="delegation-video-link" name="delegation_preferences[video_link]" value={@preferences["video_link"]} type="url" /></.field>
        </div>
        <.checkbox_field label="Suggest tasks to delegate" name="delegation_preferences[proposals_enabled]" checked={@preferences["proposals_enabled"]} />
        <div class="flex justify-end"><.button type="submit">Save preferences</.button></div>
      </.form>
    </details>
    """
  end
end
