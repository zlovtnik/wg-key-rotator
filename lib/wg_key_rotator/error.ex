defmodule WgKeyRotator.Error do
  defexception [:step, :message, :details]

  @type t :: %__MODULE__{
          step: atom(),
          message: String.t(),
          details: String.t() | nil
        }

  @impl true
  def exception(opts) do
    %__MODULE__{
      step: Keyword.fetch!(opts, :step),
      message: Keyword.fetch!(opts, :message),
      details: Keyword.get(opts, :details)
    }
  end

  def format(%__MODULE__{step: step, message: message, details: details}) do
    prefix = "#{step}: #{message}"

    case details do
      nil -> prefix
      "" -> prefix
      details -> prefix <> "\n" <> to_string(details)
    end
  end
end
