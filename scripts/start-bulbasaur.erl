Price =
    case os:getenv("BULBASAUR_PROCESS_PRICE") of
        false -> 1;
        RawPrice -> list_to_integer(RawPrice)
    end.

Port =
    case os:getenv("HB_PORT") of
        false -> 8734;
        RawPort -> list_to_integer(RawPort)
    end.

WalletPath =
    case os:getenv("HB_KEY") of
        false -> <<"bulbasaur-wallet.json">>;
        RawWalletPath -> list_to_binary(RawWalletPath)
    end.

AOToken =
    case os:getenv("BULBASAUR_AO_TOKEN") of
        false -> <<"0syT13r0s0tgPmIed95bJnuSqaD29HQNN8D3ElLSrsc">>;
        RawToken -> list_to_binary(RawToken)
    end.

LedgerProcPath =
    case os:getenv("BULBASAUR_LEDGER_PROCESS_FILE") of
        false -> <<"priv/bulbasaur-ledger-process.term">>;
        RawLedgerProcPath -> list_to_binary(RawLedgerProcPath)
    end.

{ok, TokenScript} = file:read_file("scripts/hyper-token.lua").
{ok, ProcessScript} = file:read_file("scripts/hyper-token-p4.lua").

Wallet = hb:wallet(WalletPath).
Operator = hb:address(Wallet).
LedgerCommitOpts = #{
    priv_wallet => Wallet,
    <<"priv-wallet">> => Wallet
}.

LedgerBaseDef =
    #{
        <<"device">> => <<"process@1.0">>,
        <<"execution-device">> => <<"lua@5.3a">>,
        <<"scheduler-device">> => <<"scheduler@1.0">>,
        <<"scheduler">> => [Operator],
        <<"authority">> => [Operator],
        <<"admin">> => Operator,
        <<"token">> => AOToken,
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
    }.

LedgerProc =
    case file:read_file(LedgerProcPath) of
        {ok, LedgerProcBin} ->
            binary_to_term(LedgerProcBin);
        {error, enoent} ->
            NewLedgerProc =
                hb_message:commit(
                    LedgerBaseDef,
                    LedgerCommitOpts,
                    <<"httpsig@1.0">>
                ),
            ok = filelib:ensure_dir(binary_to_list(LedgerProcPath)),
            ok = file:write_file(LedgerProcPath, term_to_binary(NewLedgerProc)),
            NewLedgerProc;
        {error, LedgerProcReadError} ->
            error({failed_to_read_ledger_process, LedgerProcPath, LedgerProcReadError})
    end.
LedgerProcessID =
    hb_util:human_id(hb_message:id(LedgerProc, signed, LedgerCommitOpts)).

{ok, LedgerCacheID} =
    hb_cache:write(
        LedgerProc,
        LedgerCommitOpts
    ).
LedgerCachePath = hb_util:human_id(LedgerCacheID).
LedgerPath = <<"/", LedgerProcessID/binary, "~process@1.0">>.

Processor =
    #{
        <<"device">> => <<"p4@1.0">>,
        <<"ledger-device">> => <<"process-ledger@1.0">>,
        <<"pricing-device">> => <<"simple-pay@1.0">>,
        <<"ledger-path">> => LedgerPath
    }.

Opts =
    #{
        port => Port,
        <<"port">> => Port,
        priv_key_location => WalletPath,
        priv_wallet => Wallet,
        <<"priv-key-location">> => WalletPath,
        <<"priv-wallet">> => Wallet,
        operator => Operator,
        p4_recipient => Operator,
        <<"operator">> => Operator,
        <<"p4-recipient">> => Operator,
        simple_pay_price => 0,
        <<"simple-pay-price">> => 0,
        p4_non_chargable_routes => [
            #{ <<"template">> => <<"/*~node-process@1.0/*">> },
            #{ <<"template">> => << LedgerPath/binary, "/*" >> },
            #{ <<"template">> => <<"/~ao-payment@1.0/*">> },
            #{ <<"template">> => <<"/~p4@1.0/balance">> },
            #{ <<"template">> => <<"/~meta@1.0/*">> }
        ],
        <<"p4-non-chargable-routes">> => [
            #{ <<"template">> => <<"/*~node-process@1.0/*">> },
            #{ <<"template">> => << LedgerPath/binary, "/*" >> },
            #{ <<"template">> => <<"/~ao-payment@1.0/*">> },
            #{ <<"template">> => <<"/~p4@1.0/balance">> },
            #{ <<"template">> => <<"/~meta@1.0/*">> }
        ],
        ao_payment_token => AOToken,
        <<"ao-payment-token">> => AOToken,
        ao_payment_ledger => LedgerProcessID,
        <<"ao-payment-ledger">> => LedgerProcessID,
        ao_payment_node => <<"http://localhost:", (integer_to_binary(Port))/binary>>,
        <<"ao-payment-node">> => <<"http://localhost:", (integer_to_binary(Port))/binary>>,
        ao_payment_mainnet_url => <<"https://state.forward.computer">>,
        <<"ao-payment-mainnet-url">> => <<"https://state.forward.computer">>,
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
        local_names => #{
            <<"ledger">> => LedgerCachePath
        },
        <<"local-names">> => #{
            <<"ledger">> => LedgerCachePath
        },
        on => #{
            <<"request">> => Processor,
            <<"response">> => Processor
        },
        <<"on">> => #{
            <<"request">> => Processor,
            <<"response">> => Processor
        }
    }.

Node = hb_http_server:start_node(Opts).
{ok, _LedgerScheduleRes} = hb_http:post(Node, <<"/schedule">>, LedgerProc, Opts).

io:format(
    "~nBulbasaur paid-process node started at ~s~n"
    "Operator: ~s~n"
    "Wallet: ~s~n"
    "Process route price: ~p AO base unit(s)~n"
    "AO root token: ~s~n"
    "Ledger process file: ~s~n"
    "Ledger AO funding account: ~s~n"
    "Ledger route: ~s~n"
    "Ledger local cache ID: ~s~n~n",
    [
        Node,
        Operator,
        WalletPath,
        Price,
        AOToken,
        LedgerProcPath,
        LedgerProcessID,
        LedgerPath,
        LedgerCachePath
    ]
).

%% Keep the evaluator process alive. The HTTP server started by
%% hb_http_server:start_node/1 is linked to this process, so returning to the
%% shell prompt would tear the listener down immediately.
receive
    stop ->
        ok
after
    infinity ->
        ok
end.
