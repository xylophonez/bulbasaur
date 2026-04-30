%%% @doc P4 ledger adapter for AO-Core process-backed token ledgers.
%%%
%%% This device reads balances from a configured `process@1.0' ledger and pushes
%%% operator-signed charge messages back into that process.
-module(dev_process_ledger).
-export([balance/3, charge/3]).
-include("include/hb.hrl").

%% @doc Read the target account balance from the configured ledger process.
balance(Base, Req, NodeMsg) ->
    case {ledger_path(Base, NodeMsg), balance_target(Req, NodeMsg)} of
        {undefined, _} ->
            {error, #{
                <<"status">> => 500,
                <<"body">> => <<"Missing process ledger path.">>
            }};
        {_, undefined} ->
            {ok, 0};
        {LedgerPath, Target} ->
            case hb_ao:resolve(
                #{ <<"path">> => <<LedgerPath/binary, "/now/balance/", Target/binary>> },
                NodeMsg
            ) of
                {ok, Balance} -> {ok, Balance};
                {error, _} -> {ok, 0}
            end
    end.

%% @doc Apply a p4 charge by pushing the signed charge request to the ledger.
charge(Base, Req, NodeMsg) ->
    case ledger_path(Base, NodeMsg) of
        undefined ->
            {error, #{
                <<"status">> => 500,
                <<"body">> => <<"Missing process ledger path.">>
            }};
        LedgerPath ->
            hb_ao:resolve(
                #{
                    <<"path">> => <<"(", LedgerPath/binary, ")/push">>,
                    <<"method">> => <<"POST">>,
                    <<"body">> => Req
                },
                NodeMsg
            )
    end.

ledger_path(Base, NodeMsg) ->
    hb_ao:get(<<"ledger-path">>, Base, undefined, NodeMsg).

balance_target(Req, NodeMsg) ->
    case target_from_message(Req, NodeMsg) of
        undefined ->
            case hb_ao:get(<<"request">>, Req, undefined, NodeMsg#{ hashpath => ignore }) of
                undefined -> undefined;
                NestedReq -> target_from_message(NestedReq, NodeMsg)
            end;
        Target ->
            Target
    end.

target_from_message(Msg, NodeMsg) ->
    case normalize_target(hb_ao:get(<<"target">>, Msg, undefined, NodeMsg)) of
        undefined ->
            case hb_message:signers(Msg, NodeMsg) of
                [] -> undefined;
                [Signer | _] -> normalize_target(Signer)
            end;
        Target ->
            Target
    end.

normalize_target(Target) when is_binary(Target) ->
    try hb_util:human_id(Target)
    catch _:_ -> Target
    end;
normalize_target(_) ->
    undefined.
