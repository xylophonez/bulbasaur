-module(bulbasaur_e2e).

-export([run/0]).

run() ->
    Price = env_int("BULBASAUR_PROCESS_PRICE", 1),
    Port = env_int("HB_PORT", 18901),
    AOToken = env_bin("BULBASAUR_AO_TOKEN", <<"0syT13r0s0tgPmIed95bJnuSqaD29HQNN8D3ElLSrsc">>),
    StoreName = list_to_binary(io_lib:format("cache-bulbasaur-e2e-~p", [Port])),
    HostWallet = hb:wallet(<<"bulbasaur-wallet.json">>),
    Operator = hb:address(HostWallet),
    LedgerCommitOpts = #{
        priv_wallet => HostWallet,
        <<"priv-wallet">> => HostWallet
    },
    UnfundedWallet = ar_wallet:new(),
    FundedWallet = ar_wallet:new(),
    FundedAddress = hb_util:human_id(ar_wallet:to_address(FundedWallet)),
    SchedulerLocation = hb_util:human_id(ar_wallet:to_address(HostWallet)),
    {ok, LuaModule} = file:read_file("scripts/bulbasaur-process.lua"),
    {ok, ClientScript} = file:read_file("scripts/bulbasaur-token-p4-client.lua"),
    {ok, TokenScript} = file:read_file("scripts/hyper-token.lua"),
    {ok, ProcessScript} = file:read_file("scripts/hyper-token-p4.lua"),

    Processor =
        #{
            <<"device">> => <<"p4@1.0">>,
            <<"ledger-device">> => <<"lua@5.3a">>,
            <<"pricing-device">> => <<"simple-pay@1.0">>,
            <<"ledger-path">> => <<"/ledger~node-process@1.0">>,
            <<"module">> => #{
                <<"content-type">> => <<"text/x-lua">>,
                <<"name">> => <<"scripts/bulbasaur-token-p4-client.lua">>,
                <<"body">> => ClientScript
            }
        },

    LedgerBaseDef =
        #{
            <<"device">> => <<"process@1.0">>,
            <<"execution-device">> => <<"lua@5.3a">>,
            <<"scheduler-device">> => <<"scheduler@1.0">>,
            <<"scheduler">> => [Operator],
            <<"authority">> => [Operator],
            <<"admin">> => Operator,
            <<"token">> => AOToken,
            <<"balance">> => #{ FundedAddress => 100 },
            <<"module">> => [
                #{
                    <<"content-type">> => <<"text/x-lua">>,
                    <<"name">> => <<"scripts/hyper-token.lua">>,
                    <<"body">> => TokenScript
                },
                #{
                    <<"content-type">> => <<"text/x-lua">>,
                    <<"name">> => <<"scripts/hyper-token-p4.lua">>,
                    <<"body">> => ProcessScript
                }
            ]
        },
    LedgerProc =
        hb_message:commit(
            LedgerBaseDef,
            LedgerCommitOpts,
            <<"httpsig@1.0">>
        ),
    LedgerProcessID =
        hb_util:human_id(hb_message:id(LedgerProc, signed, LedgerCommitOpts)),

    Opts =
        #{
            port => Port,
            priv_key_location => <<"bulbasaur-wallet.json">>,
            priv_wallet => HostWallet,
            <<"priv-key-location">> => <<"bulbasaur-wallet.json">>,
            <<"priv-wallet">> => HostWallet,
            operator => Operator,
            p4_recipient => Operator,
            <<"operator">> => Operator,
            <<"p4-recipient">> => Operator,
            simple_pay_price => 0,
            <<"simple-pay-price">> => 0,
            store => #{
                <<"store-module">> => hb_store_fs,
                <<"name">> => StoreName
            },
            <<"store">> => #{
                <<"store-module">> => hb_store_fs,
                <<"name">> => StoreName
            },
            p4_non_chargable_routes => [
                #{ <<"template">> => <<"/*~node-process@1.0/*">> },
                #{ <<"template">> => <<"/~p4@1.0/balance">> },
                #{ <<"template">> => <<"/~meta@1.0/*">> }
            ],
            <<"p4-non-chargable-routes">> => [
                #{ <<"template">> => <<"/*~node-process@1.0/*">> },
                #{ <<"template">> => <<"/~p4@1.0/balance">> },
                #{ <<"template">> => <<"/~meta@1.0/*">> }
            ],
            router_opts => #{
                <<"offered">> => [
                    #{
                        <<"template">> => <<"/.*~process@1.0/.*">>,
                        <<"price">> => Price
                    }
                ]
            },
            <<"router-opts">> => #{
                <<"offered">> => [
                    #{
                        <<"template">> => <<"/.*~process@1.0/.*">>,
                        <<"price">> => Price
                    }
                ]
            },
            <<"node-processes">> => #{
                <<"ledger">> => LedgerBaseDef
            },
            on => #{
                <<"request">> => Processor,
                <<"response">> => Processor
            },
            <<"on">> => #{
                <<"request">> => Processor,
                <<"response">> => Processor
            }
        },

    Node = hb_http_server:start_node(Opts),

    Proc =
        hb_message:commit(
            #{
                <<"device">> => <<"process@1.0">>,
                <<"scheduler-device">> => <<"scheduler@1.0">>,
                <<"scheduler-location">> => SchedulerLocation,
                <<"type">> => <<"Process">>,
                <<"execution-device">> => <<"lua@5.3a">>,
                <<"authority">> => SchedulerLocation,
                <<"module">> => #{
                    <<"content-type">> => <<"application/lua">>,
                    <<"name">> => <<"scripts/bulbasaur-process.lua">>,
                    <<"body">> => LuaModule
                }
            },
            Opts
        ),
    ProcID = hb_util:human_id(hb_message:id(Proc, all, Opts)),
    {ok, _ProcScheduleRes} = hb_http:post(Node, <<"/schedule">>, Proc, Opts),

    ScheduledMessage =
        hb_message:commit(
            #{
                <<"target">> => ProcID,
                <<"type">> => <<"Message">>,
                <<"action">> => <<"Ping">>,
                <<"test-label">> => <<"PAID PROCESS TEST">>
            },
            Opts
        ),
    {ok, _MsgScheduleRes} =
        hb_http:post(Node, << ProcID/binary, "/schedule">>, ScheduledMessage, Opts),

    UnfundedCompute = compute_request(ProcID, UnfundedWallet),
    NoBalanceRes = hb_http:get(Node, UnfundedCompute, Opts),
    case NoBalanceRes of
        {error, #{ <<"status">> := 402 }} -> ok;
        {error, #{ <<"body">> := <<"Insufficient funds">> }} -> ok;
        OtherNoBalance -> error({expected_402_without_balance, OtherNoBalance})
    end,

    BalancePath = <<"/ledger~node-process@1.0/now/balance/", FundedAddress/binary>>,
    {ok, 100} = hb_http:get(Node, BalancePath, Opts),

    FundedCompute = compute_request(ProcID, FundedWallet),
    {ok, ComputeRes} = hb_http:get(Node, FundedCompute, Opts),
    case hb_ao:get(<<"results/output/body">>, ComputeRes, Opts) of
        <<"bulbasaur-deployed-process-ok">> -> ok;
        OtherBody -> error({unexpected_compute_body, OtherBody})
    end,
    case hb_ao:get(<<"count">>, ComputeRes, Opts) of
        1 -> ok;
        OtherCount -> error({unexpected_compute_count, OtherCount})
    end,

    {ok, FinalBalance} = hb_http:get(Node, BalancePath, Opts),
    ExpectedFinalBalance = 100 - Price,
    ExpectedFinalBalance = FinalBalance,

    io:format(
        "Bulbasaur paid process E2E passed~n"
        "Node: ~s~n"
        "AO root token: ~s~n"
        "Ledger process: ~s~n"
        "Funded client: ~s~n"
        "Process: ~s~n"
        "Seeded balance: 100~n"
        "No-balance request: 402~n"
        "Paid compute: ok~n"
        "Final balance: ~p~n",
        [Node, AOToken, LedgerProcessID, FundedAddress, ProcID, FinalBalance]
    ),
    ok.

compute_request(ProcID, Wallet) ->
    hb_message:commit(
        #{
            <<"path">> => <<"/", ProcID/binary, "~process@1.0/compute">>,
            <<"slot">> => 0
        },
        #{ <<"priv-wallet">> => Wallet }
    ).

env_bin(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        RawValue -> list_to_binary(RawValue)
    end.

env_int(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        RawValue -> list_to_integer(RawValue)
    end.
