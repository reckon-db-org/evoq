%% @doc A checkpoint store that says a projection had already reached
%% position 0, so a restart has something to resume from.
-module(evoq_projection_resume_checkpoint).

-export([load/1, save/2]).

load(_ProjectionName) -> {ok, 0}.

save(_ProjectionName, _Checkpoint) -> ok.
