defmodule LambdaEthereumConsensus.Validator do
  @moduledoc """
  Functions for performing validator duties.
  """
  alias LambdaEthereumConsensus.StateTransition.Accessors
  alias LambdaEthereumConsensus.StateTransition.Misc
  alias Types.BeaconState

  @doc """
    Return the committee assignment in the ``epoch`` for ``validator_index``.
    ``assignment`` returned is a tuple of the following form:
        * ``assignment[0]`` is the list of validators in the committee
        * ``assignment[1]`` is the index to which the committee is assigned
        * ``assignment[2]`` is the slot at which the committee is assigned
    Return `nil` if no assignment.
  """
  @spec get_committee_assignment(BeaconState.t(), Types.epoch(), Types.validator_index()) ::
          {:ok, nil | {[Types.validator_index()], Types.uint64(), Types.slot()}}
          | {:error, String.t()}
  def get_committee_assignment(%BeaconState{} = state, epoch, validator_index) do
    next_epoch = Accessors.get_current_epoch(state) + 1

    if epoch > next_epoch do
      {:error, "epoch must be <= next_epoch"}
    else
      start_slot = Misc.compute_start_slot_at_epoch(epoch)
      committee_count_per_slot = Accessors.get_committee_count_per_slot(state, epoch)
      end_slot = start_slot + ChainSpec.get("SLOTS_PER_EPOCH")

      start_slot..end_slot
      |> Stream.map(fn slot ->
        0..(committee_count_per_slot - 1)
        |> Stream.map(&compute_duties(state, slot, validator_index, &1))
        |> Enum.find(&(not is_nil(&1)))
      end)
      |> Enum.find(&(not is_nil(&1)))
      |> then(&{:ok, &1})
    end
  end

  defp compute_duties(state, slot, validator_index, committee_index) do
    case Accessors.get_beacon_committee(state, slot, committee_index) do
      {:ok, committee} ->
        if Enum.member?(committee, validator_index) do
          {committee, committee_index, slot}
        end

      {:error, _} ->
        nil
    end
  end
end