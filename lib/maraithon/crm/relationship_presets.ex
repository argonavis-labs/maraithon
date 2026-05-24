defmodule Maraithon.Crm.RelationshipPresets do
  @moduledoc """
  Shared relationship labels that help operator UI and assistant context speak
  about people consistently.
  """

  @groups [
    %{
      label: "Family & personal",
      presets: [
        %{
          id: "spouse_partner",
          label: "Spouse / partner",
          value: "Spouse / partner",
          domain: "family"
        },
        %{id: "child", label: "Child", value: "Child", domain: "family"},
        %{id: "parent", label: "Parent", value: "Parent", domain: "family"},
        %{id: "sibling", label: "Sibling", value: "Sibling", domain: "family"},
        %{
          id: "extended_family",
          label: "Extended family",
          value: "Extended family",
          domain: "family"
        },
        %{id: "friend", label: "Friend", value: "Friend", domain: "personal"},
        %{
          id: "family_event_organizer",
          label: "Family event organizer",
          value: "Family event organizer",
          domain: "family"
        },
        %{
          id: "school_contact",
          label: "School / child-care",
          value: "School or child-care contact",
          domain: "family"
        },
        %{
          id: "household_service",
          label: "Household service",
          value: "Household service provider",
          domain: "personal"
        },
        %{
          id: "medical_provider",
          label: "Medical provider",
          value: "Medical provider",
          domain: "personal"
        }
      ]
    },
    %{
      label: "Business",
      presets: [
        %{id: "teammate", label: "Teammate", value: "Teammate", domain: "business"},
        %{id: "customer", label: "Customer", value: "Customer", domain: "business"},
        %{
          id: "customer_sponsor",
          label: "Customer sponsor",
          value: "Customer sponsor",
          domain: "business"
        },
        %{id: "prospect", label: "Prospect", value: "Prospect", domain: "business"},
        %{id: "investor", label: "Investor", value: "Investor", domain: "business"},
        %{
          id: "business_partner",
          label: "Business partner",
          value: "Business partner",
          domain: "business"
        },
        %{id: "vendor", label: "Vendor", value: "Vendor", domain: "business"},
        %{id: "advisor", label: "Advisor", value: "Advisor", domain: "business"},
        %{
          id: "candidate",
          label: "Candidate / hiring",
          value: "Candidate or hiring contact",
          domain: "business"
        }
      ]
    }
  ]

  @cadence_options [
    %{value: "frequent", label: "Frequent"},
    %{value: "weekly", label: "Weekly"},
    %{value: "monthly", label: "Monthly"},
    %{value: "quarterly", label: "Quarterly"},
    %{value: "occasional", label: "Occasional"},
    %{value: "rare", label: "Rare"}
  ]

  @channel_options [
    %{value: "email", label: "Email"},
    %{value: "gmail", label: "Gmail"},
    %{value: "slack", label: "Slack"},
    %{value: "telegram", label: "Telegram"},
    %{value: "phone", label: "Phone"},
    %{value: "whatsapp", label: "WhatsApp"}
  ]

  def groups, do: @groups
  def cadence_options, do: @cadence_options
  def channel_options, do: @channel_options

  def all do
    Enum.flat_map(@groups, & &1.presets)
  end

  def get(nil), do: nil

  def get(preset_id) when is_binary(preset_id) do
    Enum.find(all(), &(&1.id == preset_id))
  end

  def get(_preset_id), do: nil

  def value(nil), do: nil

  def value(preset_id) do
    case get(preset_id) do
      nil -> nil
      preset -> preset.value
    end
  end
end
