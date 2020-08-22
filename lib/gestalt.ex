defmodule Gestalt do
  @moduledoc """
  Provides a wrapper for `Application.get_env/3` and `System.get_env/1`, where configuration
  can be overridden on a per-process basis. This allows asynchronous tests to change
  configuration on the fly without altering global state for other tests.


  ## Usage

  In `test_helper.exs`, add the following:

      {:ok, _} = Gestalt.start()

  In runtime code, where one would use `Application.get_env/3`,

      value = Application.get_env(:my_module, :my_config)

  instead the following could be used:

      value = Gestalt.get_config(:my_module, :my_config, self())

  In runtime code, where one would use `System.get_env/1`,

      value = System.get_env("VARIABLE_NAME")

  instead the following could be used:

      value = Gestalt.get_env("VARIABLE_NAME", self())


  ## Overriding values in tests

  The value of Gestalt comes from its ability to change configuration and/or environment
  in a way that only effects the current process. For instance, if code behaves differently
  depending on configuration, then a test that uses `Application.put_env/4` to verify its
  effect will change global state for other asynchronously-running tests.

  To change Application configuration, use the following:

      Gestalt.replace_config(:my_module, :my_value, "some value", self())

  To change System environment, use the following:

      Gestalt.replace_env("VARIABLE_NAME", "some value", self())


  ## Caveats

  Gestalt does not try to be too smart about merging overrides with existing configuration.
  If an override is set for the current pid, then all config and env values required by the
  runtime code must be specifically set.

  Also, note that Gestalt is a runtime configuration library. Values used by module variables
  are evaluated at compile time, not at runtime.

  """

  alias Gestalt.Util

  defmacro __using__(_) do
    quote do
      import Gestalt.Macros
    end
  end

  @doc ~S"""
  Starts an agent for storing override values. If an agent is already running, it
  is returned.

  ## Examples

      iex> {:ok, pid} = Gestalt.start()
      iex> is_pid(pid)
      true
      iex> {:ok, other_pid} = Gestalt.start()
      iex> pid == other_pid
      true

  """
  def start(agent \\ __MODULE__) do
    case GenServer.whereis(agent) do
      nil -> Agent.start_link(fn -> %{} end, name: agent)
      server -> {:ok, server}
    end
  end

  @doc ~S"""
  Copies Gestalt overrides from one pid to another. If no overrides have been defined,
  returns `nil`.
  """
  def copy(from_pid, to_pid, agent \\ __MODULE__)

  def copy(from_pid, to_pid, agent) when is_pid(from_pid) and is_pid(to_pid) do
    unless GenServer.whereis(agent),
      do: raise("agent not started, please call start() before changing state")

    Agent.get_and_update(agent, fn state ->
      get_in(state, [from_pid])
      |> case do
        nil -> {nil, state}
        overrides -> {overrides, state |> Map.put(to_pid, overrides)}
      end
    end)
  end

  @doc ~S"""
  Copies Gestalt overrides from one pid to another. If no overrides have been defined,
  raises a RuntimeError.
  """
  def copy!(from_pid, to_pid, agent \\ __MODULE__)

  def copy!(from_pid, to_pid, agent) when is_pid(from_pid) and is_pid(to_pid) do
    copy(from_pid, to_pid, agent)
    |> case do
      nil -> raise("copy!/2 expected overrides for pid: #{inspect(from_pid)}, but none found")
      _overrides -> :ok
    end
  end

  @doc ~S"""
  Gets configuration either from Application, or from the running agent.

  ## Examples

      iex> {:ok, _pid} = Gestalt.start()
      iex> Application.put_env(:module_name, :key_name, true)
      iex> Gestalt.get_config(:module_name, :key_name, self())
      true
      iex> Gestalt.replace_config(:module_name, :key_name, false, self())
      :ok
      iex> Gestalt.get_config(:module_name, :key_name, self())
      false

  """
  @spec get_config(atom(), any(), pid()) :: any()
  @spec get_config(atom(), any(), pid(), module()) :: any()
  def get_config(_module, _key, _pid, _agent \\ __MODULE__)

  def get_config(module, key, pid, agent) when is_pid(pid) do
    case GenServer.whereis(agent) do
      nil -> Application.get_env(module, key)
      _ -> get_agent_config(agent, pid, module, key)
    end
  end

  def get_config(_module, _key, _pid, _agent), do: raise("get_config/3 must receive a pid")

  @doc ~S"""
  Gets environment variables either from System, or from the running agent.

  ## Examples

      iex> {:ok, _pid} = Gestalt.start()
      iex> System.put_env("VARIABLE_FROM_ENV", "value set from env")
      iex> Gestalt.get_env("VARIABLE_FROM_ENV", self())
      "value set from env"
      iex> Gestalt.replace_env("VARIABLE_FROM_ENV", "no longer from env", self())
      :ok
      iex> Gestalt.get_env("VARIABLE_FROM_ENV", self())
      "no longer from env"

  """
  @spec get_env(String.t(), pid()) :: any()
  @spec get_env(String.t(), pid(), module()) :: any()
  def get_env(_variable, _pid, _agent \\ __MODULE__)

  def get_env(variable, pid, agent) when is_pid(pid) do
    case GenServer.whereis(agent) do
      nil -> System.get_env(variable)
      _ -> get_agent_env(agent, pid, variable)
    end
  end

  def get_env(_variable, _pid, _agent), do: raise("get_env/2 must receive a pid")

  ##############################
  ## Modify state
  ##############################

  @doc ~S"""
  Sets an override for the provided pid, effecting the behavior of `get_config/4`.
  """
  @spec replace_config(atom(), any(), any(), pid()) :: :ok
  @spec replace_config(atom(), any(), any(), pid(), module()) :: :ok
  def replace_config(_module, _key, _value, _pid, _agent \\ __MODULE__)

  def replace_config(module, key, value, pid, agent) when is_pid(pid) do
    case GenServer.whereis(agent) do
      nil ->
        raise "agent not started, please call start() before changing state"

      _ ->
        Agent.update(agent, fn state ->
          update_map = %{module => %{key => value}}

          overrides =
            (get_in(state, [pid]) || [configuration: %{}])
            |> Keyword.update(:configuration, update_map, &Util.Map.deep_merge(&1, update_map))

          Map.put(state, pid, overrides)
        end)
    end
  end

  def replace_config(_module, _key, _value, _pid, _agent), do: raise("replace_config/4 must receive a pid")

  @doc ~S"""
  Sets an override for the provided pid, effecting the behavior of `get_env/3`.
  """
  @spec replace_env(String.t(), any(), pid()) :: :ok
  @spec replace_env(String.t(), any(), pid(), module()) :: :ok
  def replace_env(_variable, _value, _pid, _agent \\ __MODULE__)

  def replace_env(variable, value, pid, agent) when is_pid(pid) do
    case GenServer.whereis(agent) do
      nil ->
        raise "agent not started, please call start() before changing state"

      _ ->
        Agent.update(agent, fn state ->
          overrides =
            (get_in(state, [pid]) || [env: %{}])
            |> Keyword.update(:env, %{variable => value}, &Map.put(&1, variable, value))

          Map.put(state, pid, overrides)
        end)
    end
  end

  def replace_env(_variable, _value, _pid, _agent), do: raise("replace_env/3 must receive a pid")

  ##############################
  ## Private
  ##############################

  defp get_agent_config(agent, caller_pid, module, key) do
    Agent.get(agent, fn state ->
      get_in(state, [caller_pid, :configuration])
    end)
    |> case do
      nil ->
        Application.get_env(module, key)

      override ->
        case Map.has_key?(override, module) && Map.has_key?(override[module], key) do
          false -> Application.get_env(module, key)
          true -> get_in(override, [module, key])
        end
    end
  end

  defp get_agent_env(agent, caller_pid, variable) when is_binary(variable) do
    Agent.get(agent, fn state ->
      get_in(state, [caller_pid, :env])
    end)
    |> case do
      nil ->
        System.get_env(variable)

      override ->
        case Map.has_key?(override, variable) do
          false -> System.get_env(variable)
          true -> override[variable]
        end
    end
  end
end
