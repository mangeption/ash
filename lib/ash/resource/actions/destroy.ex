defmodule Ash.Resource.Actions.Destroy do
  @moduledoc "The representation of a `destroy` action"

  defstruct [:type, :name, :primary?, :authorization_steps]

  @type t :: %__MODULE__{
          type: :destroy,
          name: atom,
          primary?: boolean,
          authorization_steps: Authorization.steps()
        }

  @opt_schema Ashton.schema(
                opts: [
                  primary?: :boolean,
                  authorization_steps: :keyword
                ],
                defaults: [
                  primary?: false,
                  authorization_steps: []
                ],
                describe: [
                  primary?:
                    "Whether or not this action should be used when no action is specified by the caller.",
                  # TODO: doc better
                  authorization_steps: "A list of authorization steps"
                ]
              )

  @doc false
  def opt_schema(), do: @opt_schema

  @spec new(Ash.resource(), atom, Keyword.t()) :: {:ok, t()} | {:error, term}
  def new(resource, name, opts \\ []) do
    # Don't call functions on the resource! We don't want it to compile here
    case Ashton.validate(opts, @opt_schema) do
      {:ok, opts} ->
        authorization_steps =
          case opts[:authorization_steps] do
            false ->
              false

            steps ->
              base_attribute_opts = [
                resource: resource
              ]

              Enum.map(steps, fn {step, {mod, opts}} ->
                {step, {mod, Keyword.merge(base_attribute_opts, opts)}}
              end)
          end

        {:ok,
         %__MODULE__{
           name: name,
           type: :destroy,
           primary?: opts[:primary?],
           authorization_steps: authorization_steps
         }}

      {:error, error} ->
        {:error, error}
    end
  end
end
