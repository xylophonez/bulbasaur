Price =
    case os:getenv("BULBASAUR_PROCESS_PRICE") of
        false -> 1;
        RawPrice -> list_to_integer(RawPrice)
    end.

BundlerBytePrice =
    case os:getenv("BULBASAUR_BUNDLER_BYTE_PRICE") of
        false -> 1162726;
        RawBundlerBytePrice -> list_to_integer(RawBundlerBytePrice)
    end.

BundlerMaxItems =
    case os:getenv("BULBASAUR_BUNDLER_MAX_ITEMS") of
        false -> 1000;
        RawBundlerMaxItems -> list_to_integer(RawBundlerMaxItems)
    end.

Port =
    case os:getenv("HB_PORT") of
        false -> 8734;
        RawPort -> list_to_integer(RawPort)
    end.
PrimaryStore = #{
    <<"store-module">> => hb_store_fs,
    <<"name">> => <<"cache-bulbasaur-", (integer_to_binary(Port))/binary>>
}.
ArweaveStore = #{
    <<"store-module">> => hb_store_arweave,
    <<"name">> => <<"cache-bulbasaur-arweave-", (integer_to_binary(Port))/binary>>,
    <<"index-store">> => [PrimaryStore],
    <<"local-store">> => [PrimaryStore]
}.
Store = [PrimaryStore, ArweaveStore].

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
Beneficiary =
    case os:getenv("BULBASAUR_BENEFICIARY") of
        false -> Operator;
        RawBeneficiary -> list_to_binary(RawBeneficiary)
    end.
InitialBalance =
    case {os:getenv("BULBASAUR_INITIAL_BALANCE_ADDRESS"), os:getenv("BULBASAUR_INITIAL_BALANCE")} of
        {false, _} -> #{};
        {_, false} -> #{};
        {RawBalanceAddress, RawBalance} ->
            #{ list_to_binary(RawBalanceAddress) => list_to_integer(RawBalance) }
    end.
LedgerCommitOpts = #{
    priv_wallet => Wallet,
    <<"priv-wallet">> => Wallet,
    store => Store,
    <<"store">> => Store
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
        <<"balance">> => InitialBalance,
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

NewLedgerProc =
    fun() ->
        Proc =
            hb_message:commit(
                LedgerBaseDef,
                LedgerCommitOpts,
                <<"httpsig@1.0">>
            ),
        ok = filelib:ensure_dir(binary_to_list(LedgerProcPath)),
        ok = file:write_file(LedgerProcPath, term_to_binary(Proc)),
        Proc
    end.

LedgerProc =
    case file:read_file(LedgerProcPath) of
        {ok, LedgerProcBin} ->
            ExistingLedgerProc = binary_to_term(LedgerProcBin),
            case hb_message:signers(ExistingLedgerProc, LedgerCommitOpts) of
                [] ->
                    io:format(
                        "Regenerating unsigned/stale ledger process file: ~s~n",
                        [LedgerProcPath]
                    ),
                    NewLedgerProc();
                _ ->
                    ExistingLedgerProc
            end;
        {error, enoent} ->
            NewLedgerProc();
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
LedgerPath = <<"/ledger~node-process@1.0">>.

Processor =
    #{
        <<"device">> => <<"p4@1.0">>,
        <<"ledger-device">> => <<"process-ledger@1.0">>,
        <<"pricing-device">> => <<"pricing-router@1.0">>,
        <<"default-pricing-device">> => <<"simple-pay@1.0">>,
        <<"ledger-path">> => LedgerPath,
        <<"pricing-routes">> => [
            #{
                <<"template">> => <<"/~bundler@1.0/tx">>,
                <<"pricing-device">> => <<"metering@1.0">>
            },
            #{
                <<"template">> => <<"/~bundler@1.0/item">>,
                <<"pricing-device">> => <<"metering@1.0">>
            }
        ]
    }.

BundlerSettlement =
    #{
        <<"device">> => <<"bundler-settlement@1.0">>,
        <<"ledger-device">> => <<"process-ledger@1.0">>,
        <<"pricing-device">> => <<"metering@1.0">>,
        <<"ledger-path">> => LedgerPath,
        <<"settlement-account">> => Operator,
        <<"beneficiary">> => Beneficiary,
        <<"hook">> => #{ <<"result">> => <<"ignore">> }
    }.

Opts =
    #{
        port => Port,
        <<"port">> => Port,
        priv_key_location => WalletPath,
        priv_wallet => Wallet,
        <<"priv-key-location">> => WalletPath,
        <<"priv-wallet">> => Wallet,
        store => Store,
        <<"store">> => Store,
        operator => Operator,
        p4_recipient => Operator,
        <<"operator">> => Operator,
        <<"p4-recipient">> => Operator,
        bundler_beneficiary => Beneficiary,
        <<"bundler-beneficiary">> => Beneficiary,
        <<"bundler-max-items">> => BundlerMaxItems,
        arweave_index_store => ArweaveStore,
        <<"arweave-index-store">> => ArweaveStore,
        arweave_mempool_copycat_on_bundle_complete => true,
        <<"arweave-mempool-copycat-on-bundle-complete">> => true,
        arweave_mempool_progress => true,
        <<"arweave-mempool-progress">> => true,
        arweave_index_workers => 1,
        <<"arweave-index-workers">> => 1,
        arweave_pending_chunk_poll_attempts => 20,
        <<"arweave-pending-chunk-poll-attempts">> => 20,
        arweave_pending_chunk_poll_ms => 500,
        <<"arweave-pending-chunk-poll-ms">> => 500,
        simple_pay_price => 0,
        <<"simple-pay-price">> => 0,
        <<"metering-rates">> => #{
            <<"arweave-bytes">> => BundlerBytePrice,
            <<"beam-reductions">> => 0
        },
        p4_non_chargable_routes => [
            #{ <<"template">> => <<"/*~node-process@1.0/*">> },
            #{ <<"template">> => << LedgerPath/binary, "/*" >> },
            #{ <<"template">> => <<"/", LedgerProcessID/binary, "~process@1.0/*" >> },
            #{ <<"template">> => <<"/~ao-payment@1.0/*">> },
            #{ <<"template">> => <<"/~p4@1.0/balance">> },
            #{ <<"template">> => <<"/~meta@1.0/*">> }
        ],
        <<"p4-non-chargable-routes">> => [
            #{ <<"template">> => <<"/*~node-process@1.0/*">> },
            #{ <<"template">> => << LedgerPath/binary, "/*" >> },
            #{ <<"template">> => <<"/", LedgerProcessID/binary, "~process@1.0/*" >> },
            #{ <<"template">> => <<"/~ao-payment@1.0/*">> },
            #{ <<"template">> => <<"/~p4@1.0/balance">> },
            #{ <<"template">> => <<"/~meta@1.0/*">> }
        ],
        ao_payment_token => AOToken,
        <<"ao-payment-token">> => AOToken,
        ao_payment_ledger => LedgerProcessID,
        <<"ao-payment-ledger">> => LedgerProcessID,
        ao_payment_deposit_address => Operator,
        <<"ao-payment-deposit-address">> => Operator,
        ao_payment_node => <<"http://localhost:", (integer_to_binary(Port))/binary>>,
        <<"ao-payment-node">> => <<"http://localhost:", (integer_to_binary(Port))/binary>>,
        ao_payment_mainnet_url => <<"https://state.forward.computer">>,
        <<"ao-payment-mainnet-url">> => <<"https://state.forward.computer">>,
        router_opts => #{
            <<"offered">> => [
                #{
                    <<"template">> => <<"/.*~process@1.0/.*">>,
                    <<"price">> => Price
                },
                #{
                    <<"template">> => <<"/~bundler@1.0/tx">>,
                    <<"price">> => 0
                },
                #{
                    <<"template">> => <<"/~bundler@1.0/item">>,
                    <<"price">> => 0
                }
            ]
        },
        <<"router-opts">> => #{
            <<"offered">> => [
                #{
                    <<"template">> => <<"/.*~process@1.0/.*">>,
                    <<"price">> => Price
                },
                #{
                    <<"template">> => <<"/~bundler@1.0/tx">>,
                    <<"price">> => 0
                },
                #{
                    <<"template">> => <<"/~bundler@1.0/item">>,
                    <<"price">> => 0
                }
            ]
        },
        node_processes => #{
            <<"ledger">> => LedgerBaseDef
        },
        <<"node-processes">> => #{
            <<"ledger">> => LedgerBaseDef
        },
        local_names => #{
            <<"ledger">> => LedgerProcessID
        },
        <<"local-names">> => #{
            <<"ledger">> => LedgerProcessID
        },
        on => #{
            <<"request">> => Processor,
            <<"response">> => Processor,
            <<"bundled-message-complete">> => BundlerSettlement
        },
        <<"on">> => #{
            <<"request">> => Processor,
            <<"response">> => Processor,
            <<"bundled-message-complete">> => BundlerSettlement
        }
    }.

Node = hb_http_server:start_node(Opts).
{ok, _LedgerScheduleRes} = hb_http:post(Node, <<"/schedule">>, LedgerProc, Opts).

io:format(
    "~nBulbasaur paid-process node started at ~s~n"
    "Operator: ~s~n"
    "Bundler beneficiary: ~s~n"
    "Wallet: ~s~n"
    "Process route price: ~p AO base unit(s)~n"
    "Bundler byte price: ~p AO base unit(s)~n"
    "Bundler optimistic cache: enabled~n"
    "AO root token: ~s~n"
    "Ledger process file: ~s~n"
    "Ledger process ID: ~s~n"
    "AO deposit address: ~s~n"
    "Ledger route: ~s~n"
    "Ledger local cache ID: ~s~n~n",
    [
        Node,
        Operator,
        Beneficiary,
        WalletPath,
        Price,
        BundlerBytePrice,
        AOToken,
        LedgerProcPath,
        LedgerProcessID,
        Operator,
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
