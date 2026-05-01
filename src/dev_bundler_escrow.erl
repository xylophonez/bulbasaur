%%% @doc Escrow helpers for paid bundler uploads.
-module(dev_bundler_escrow).
-export([reserve/4, release/2, refund/2]).

-include("include/hb.hrl").

-define(ARWEAVE_BYTES, <<"arweave-bytes">>).

reserve(Item, ItemID, BundledSize, Opts) ->
    case processor(Opts) of
        undefined ->
            {ok, none};
        Processor ->
            case quote(Processor, BundledSize, Opts) of
                {ok, 0} ->
                    {ok, none};
                {ok, Price} ->
                    reserve_priced(Item, ItemID, BundledSize, Price, Processor, Opts);
                {error, _} = Error ->
                    Error
            end
    end.

release(none, _Opts) ->
    ok;
release(Escrow, Opts) ->
    case processor(Opts) of
        undefined ->
            ok;
        Processor ->
            Req = signed_ledger_req(
                #{
                    <<"path">> => <<"release">>,
                    <<"reservation-id">> => maps:get(<<"reservation-id">>, Escrow),
                    <<"recipient">> => maps:get(<<"recipient">>, Escrow),
                    <<"request">> => maps:get(<<"request">>, Escrow, #{})
                },
                Opts
            ),
            case hb_ao:resolve(ledger_msg(Processor), Req, Opts) of
                {ok, _} -> ok;
                Error -> Error
            end
    end.

refund(none, _Opts) ->
    ok;
refund(Escrow, Opts) ->
    case processor(Opts) of
        undefined ->
            ok;
        Processor ->
            Req = signed_ledger_req(
                #{
                    <<"path">> => <<"refund">>,
                    <<"reservation-id">> => maps:get(<<"reservation-id">>, Escrow),
                    <<"request">> => maps:get(<<"request">>, Escrow, #{})
                },
                Opts
            ),
            case hb_ao:resolve(ledger_msg(Processor), Req, Opts) of
                {ok, _} -> ok;
                Error -> Error
            end
    end.

reserve_priced(Item, ItemID, BundledSize, Price, Processor, Opts) ->
    case payer(Item, Opts) of
        undefined ->
            {error, #{
                <<"status">> => 400,
                <<"body">> => <<"Bundler item must have exactly one signer.">>
            }};
        Payer ->
            Recipient = recipient(Opts),
            ReservationID = <<ItemID/binary, "-bundler">>,
            Escrow = #{
                <<"reservation-id">> => ReservationID,
                <<"payer">> => Payer,
                <<"recipient">> => Recipient,
                <<"quantity">> => Price,
                <<"resource">> => ?ARWEAVE_BYTES,
                <<"resource-quantity">> => BundledSize,
                <<"item-id">> => ItemID,
                <<"request">> => #{ <<"item-id">> => ItemID }
            },
            Req = signed_ledger_req(
                #{
                    <<"path">> => <<"reserve">>,
                    <<"reservation-id">> => ReservationID,
                    <<"quantity">> => Price,
                    <<"account">> => Payer,
                    <<"recipient">> => Recipient,
                    <<"request">> => #{ <<"item-id">> => ItemID }
                },
                Opts
            ),
            case hb_ao:resolve(ledger_msg(Processor), Req, Opts) of
                {ok, _} -> {ok, Escrow};
                {error, Error} -> {error, Error}
            end
    end.

quote(Processor, BundledSize, Opts) ->
    PricingDevice = pricing_device(Processor, Opts),
    case PricingDevice of
        false ->
            {ok, 0};
        _ ->
            hb_ao:resolve(
                Processor#{ <<"device">> => PricingDevice },
                #{
                    <<"path">> => <<"quote">>,
                    <<"resources">> => #{ ?ARWEAVE_BYTES => BundledSize }
                },
                Opts
            )
    end.

pricing_device(Processor, _Opts) ->
    case maps:get(<<"bundler-pricing-device">>, Processor, undefined) of
        undefined ->
            case maps:get(<<"pricing-device">>, Processor, false) of
                <<"metering@1.0">> -> <<"metering@1.0">>;
                _ -> false
            end;
        Device ->
            Device
    end.

ledger_msg(Processor) ->
    LedgerDevice = maps:get(<<"ledger-device">>, Processor),
    Processor#{ <<"device">> => LedgerDevice }.

processor(Opts) ->
    case dev_hook:find(<<"request">>, Opts) of
        Handlers when is_list(Handlers) ->
            case
                lists:search(
                    fun(Processor) ->
                        maps:get(<<"ledger-device">>, Processor, false)
                            =:= <<"process-ledger@1.0">>
                    end,
                    Handlers
                )
            of
                {value, Processor} -> Processor;
                false -> undefined
            end;
        _ -> undefined
    end.

payer(Item, Opts) ->
    case hb_message:signers(Item, Opts) of
        [Signer] -> hb_util:human_id(Signer);
        _ -> undefined
    end.

recipient(Opts) ->
    case hb_opts:get(p4_recipient, undefined, Opts) of
        Addr when ?IS_ID(Addr) ->
            hb_util:human_id(Addr);
        _ ->
            hb_util:human_id(hb_opts:get(operator, undefined, Opts))
    end.

signed_ledger_req(Req, Opts) ->
    hb_message:commit(Req, Opts).
