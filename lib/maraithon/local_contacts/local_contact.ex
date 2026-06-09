defmodule Maraithon.LocalContacts.LocalContact do
  @moduledoc """
  Mirror of one macOS Contacts.app record synced from a companion device.

  Rows are upserted by `(user_id, device_id, source, guid)`, where `guid`
  is the stable `CNContact.identifier` from the Mac. The row also stores the
  CRM person it merged into so device stats and data purges stay auditable
  even after the person's contact details are folded into the CRM.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Crm.Person

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "local_contacts" do
    field :user_id, :string
    field :device_id, Ecto.UUID
    field :source, :string, default: "contacts"
    field :guid, :string
    field :local_id, :string

    field :display_name, :string
    field :first_name, :string
    field :middle_name, :string
    field :last_name, :string
    field :nickname, :string
    field :organization_name, :string
    field :department_name, :string
    field :job_title, :string

    field :emails, {:array, :string}, default: []
    field :phones, {:array, :string}, default: []
    field :urls, {:array, :string}, default: []
    field :postal_addresses, :map, default: %{}
    field :payload_hash, :string

    belongs_to :crm_person, Person, type: :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:user_id, :device_id, :source, :guid]
  @optional_fields [
    :local_id,
    :display_name,
    :first_name,
    :middle_name,
    :last_name,
    :nickname,
    :organization_name,
    :department_name,
    :job_title,
    :emails,
    :phones,
    :urls,
    :postal_addresses,
    :payload_hash,
    :crm_person_id
  ]

  def changeset(contact, attrs) do
    contact
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:source, max: 64)
    |> validate_length(:guid, max: 512)
    |> validate_length(:local_id, max: 512)
    |> validate_length(:display_name, max: 240)
    |> validate_length(:first_name, max: 120)
    |> validate_length(:middle_name, max: 120)
    |> validate_length(:last_name, max: 120)
    |> validate_length(:nickname, max: 120)
    |> validate_length(:organization_name, max: 255)
    |> validate_length(:department_name, max: 255)
    |> validate_length(:job_title, max: 255)
    |> validate_length(:payload_hash, max: 128)
    |> unique_constraint([:user_id, :device_id, :source, :guid],
      name: :local_contacts_user_device_source_guid_index
    )
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:crm_person_id)
  end
end
