%% @doc A projection that fails and implements no on_error/4.
%%
%% It stands for every projection written without an error callback: the
%% framework must still do something defined with its failure - the shared
%% default (backoff, then dead letter) - and never drop the event quietly.
-module(evoq_projection_recovery_deaf).

-behaviour(evoq_projection).

-export([interested_in/0, init/1, project/4]).

interested_in() -> [<<"recovery_probe_v1">>].

init(_Config) ->
    {ok, RM} = evoq_read_model:new(evoq_read_model_ets, #{}),
    {ok, [], RM}.

project(#{data := #{n := N}}, _Metadata, Seen, RM) ->
    case evoq_projection_recovery_script:raise_on() of
        N ->
            error({scripted_raise, N});
        _ ->
            case evoq_projection_recovery_script:take_failure(N) of
                true -> {error, {boom, N}};
                false -> {ok, Seen ++ [N], RM}
            end
    end.
