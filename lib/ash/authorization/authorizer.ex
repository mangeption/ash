defmodule Ash.Authorization.Authorizer do
  @moduledoc """
  Determines if a set of authorization requests can be met or not.

  To read more about boolean satisfiability, see this page:
  https://en.wikipedia.org/wiki/Boolean_satisfiability_problem. At the end of
  the day, however, it is not necessary to understand exactly how Ash takes your
  authorization requirements and determines if a request is allowed. The
  important thing to understand is that Ash may or may not run any/all of your
  authorization rules as they may be deemed unnecessary. As such, authorization
  checks should have no side effects. Ideally, the checks built-in to ash should
  cover the bulk of your needs.

  If you need to write your own checks see #TODO: Link to a guide about writing checks here.
  """
  @type result :: :authorized | :forbidden

  alias Ash.Authorization.{Report, Request, SatSolver}

  require Logger

  def authorize(user, requests, opts \\ []) do
    strict_access? = Keyword.get(opts, :strict_access?, true)

    if opts[:fetch_only?] do
      fetch_must_fetch(requests, %{})
    else
      case Enum.find(requests, fn request -> Enum.empty?(request.authorization_steps) end) do
        nil ->
          {new_requests, facts} = strict_check_facts(user, requests, strict_access?)

          solve(
            new_requests,
            user,
            facts,
            facts,
            %{user: user},
            strict_access?,
            opts[:log_final_report?] || false
          )

        request ->
          {:error,
           Ash.Error.Forbidden.exception(
             no_steps_configured: request,
             log_final_report?: opts[:log_final_report?] || false
           )}
      end
    end
  end

  defp solve(
         requests,
         user,
         facts,
         strict_check_facts,
         state,
         strict_access?,
         log_final_report?
       ) do
    case sat_solver(requests, facts, [], state) do
      {:error, :unsatisfiable} ->
        exception =
          Ash.Error.Forbidden.exception(
            requests: requests,
            facts: facts,
            strict_check_facts: strict_check_facts,
            strict_access?: strict_access?,
            state: state
          )

        if log_final_report? do
          Logger.info(Ash.Error.Forbidden.report_text(exception))
        end

        {:error, exception}

      {:ok, scenario} ->
        requests
        |> get_all_scenarios(scenario, facts, state)
        |> Enum.uniq()
        |> remove_irrelevant_clauses()
        |> verify_scenarios(
          user,
          requests,
          facts,
          strict_check_facts,
          state,
          strict_access?,
          log_final_report?
        )
    end
  end

  defp remove_irrelevant_clauses(scenarios) do
    new_scenarios =
      scenarios
      |> Enum.uniq()
      |> Enum.map(fn scenario ->
        unnecessary_fact =
          Enum.find_value(scenario, fn
            {_fact, :unknowable} ->
              false

            # TODO: Is this acceptable?
            # If the check refers to empty data, and its meant to bypass strict checks
            # Then we consider that fact an irrelevant fact? Probably.
            {_fact, :irrelevant} ->
              true

            {fact, value_in_this_scenario} ->
              matching =
                Enum.find(scenarios, fn potential_irrelevant_maker ->
                  potential_irrelevant_maker != scenario &&
                    Map.delete(scenario, fact) == Map.delete(potential_irrelevant_maker, fact)
                end)

              case matching do
                %{^fact => value} when is_boolean(value) and value != value_in_this_scenario ->
                  fact

                _ ->
                  false
              end
          end)

        Map.delete(scenario, unnecessary_fact)
      end)
      |> Enum.uniq()

    if new_scenarios == scenarios do
      new_scenarios
    else
      remove_irrelevant_clauses(new_scenarios)
    end
  end

  defp get_all_scenarios(
         requests,
         scenario,
         facts,
         state,
         negations \\ [],
         scenarios \\ []
       ) do
    scenario = Map.drop(scenario, [true, false])
    scenarios = [scenario | scenarios]

    case scenario_is_reality(scenario, facts) do
      :reality ->
        scenarios

      :not_reality ->
        raise "SAT SOLVER ERROR"

      :maybe ->
        negations_assuming_scenario_false = [scenario | negations]

        case sat_solver(
               requests,
               facts,
               negations_assuming_scenario_false,
               state
             ) do
          {:ok, scenario_after_negation} ->
            get_all_scenarios(
              requests,
              scenario_after_negation,
              facts,
              state,
              negations_assuming_scenario_false,
              scenarios
            )

          {:error, :unsatisfiable} ->
            scenarios
        end
    end
  end

  defp sat_solver(requests, facts, negations, state) do
    case state do
      %{data: [%resource{} | _] = data} ->
        # TODO: Needs primary key, looks like some kind of primary key is necessary for
        # almost everything ash does :/
        pkey = Ash.primary_key(resource)

        ids = Enum.map(data, &Map.take(&1, pkey))
        SatSolver.solve(requests, facts, negations, ids)

      _ ->
        SatSolver.solve(requests, facts, negations, nil)
    end
  end

  defp verify_scenarios(
         scenarios,
         user,
         requests,
         facts,
         strict_check_facts,
         state,
         strict_access?,
         log_final_report?
       ) do
    if any_scenarios_reality?(scenarios, facts) do
      if log_final_report? do
        report = %Report{
          scenarios: scenarios,
          requests: requests,
          facts: facts,
          strict_check_facts: strict_check_facts,
          state: state,
          strict_access?: strict_access?,
          authorized?: true
        }

        Logger.info(Report.report(report))
      end

      fetch_must_fetch(requests, state)
    else
      case Ash.Authorization.Checker.run_checks(
             scenarios,
             user,
             requests,
             facts,
             state,
             strict_access?
           ) do
        :all_scenarios_known ->
          exception =
            Ash.Error.Forbidden.exception(
              scenarios: scenarios,
              requests: requests,
              facts: facts,
              strict_check_facts: strict_check_facts,
              state: state,
              strict_access?: strict_access?
            )

          if log_final_report? do
            Logger.info(Ash.Error.Forbidden.report_text(exception))
          end

          {:error, exception}

        {:error, error} ->
          {:error, error}

        {:ok, new_requests, new_facts, new_state} ->
          if new_requests == requests && new_facts == new_facts && state == new_state do
            exception =
              Ash.Error.Forbidden.exception(
                scenarios: scenarios,
                requests: requests,
                facts: facts,
                strict_check_facts: strict_check_facts,
                state: state,
                strict_access?: strict_access?
              )

            if log_final_report? do
              Logger.info(Ash.Error.Forbidden.report_text(exception))
            end

            {:error, exception}
          else
            solve(
              new_requests,
              user,
              new_facts,
              strict_check_facts,
              new_state,
              strict_access?,
              log_final_report?
            )
          end
      end
    end
  end

  defp fetch_must_fetch(requests, state) do
    unfetched = Enum.reject(requests, &Request.fetched?(state, &1))

    {safe_to_fetch, unmet} =
      Enum.split_with(unfetched, fn request -> Request.dependencies_met?(state, request) end)

    case Enum.filter(safe_to_fetch, &Map.get(&1, :must_fetch?)) do
      [] ->
        if unmet == [] do
          {:ok, state}
        else
          {:error,
           "Could not fetch all required data due to data dependency issues, unmet dependencies existed"}
        end

      must_fetch ->
        new_state =
          Enum.reduce_while(must_fetch, {:ok, state}, fn request, {:ok, state} ->
            case Request.fetch(state, request) do
              {:ok, new_state} -> {:cont, {:ok, new_state}}
              {:error, error} -> {:halt, {:error, error}}
            end
          end)

        case new_state do
          {:ok, new_state} ->
            if new_state == state do
              {:error,
               "Could not fetch all required data due to data dependency issues, no step affected state"}
            else
              fetch_must_fetch(unfetched, new_state)
            end

          {:error, error} ->
            {:error, error}
        end
    end
  end

  defp any_scenarios_reality?(scenarios, facts) do
    Enum.any?(scenarios, fn scenario ->
      scenario_is_reality(scenario, facts) == :reality
    end)
  end

  defp scenario_is_reality(scenario, facts) do
    scenario
    |> Map.drop([true, false])
    |> Enum.reduce_while(:reality, fn {fact, requirement}, status ->
      case Map.fetch(facts, fact) do
        {:ok, value} ->
          cond do
            value == requirement ->
              {:cont, status}

            value == :irrelevant ->
              {:cont, status}

            value == :unknowable ->
              {:halt, :not_reality}

            true ->
              {:halt, :not_reality}
          end

        :error ->
          {:cont, :maybe}
      end
    end)
  end

  defp strict_check_facts(user, requests, strict_access?) do
    Enum.reduce(requests, {[], %{true: true, false: false}}, fn request, {requests, facts} ->
      {new_request, new_facts} =
        Ash.Authorization.Checker.strict_check(user, request, facts, strict_access?)

      {[new_request | requests], new_facts}
    end)
  end
end
