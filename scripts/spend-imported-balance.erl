Node =
    case os:getenv("HB_NODE") of
        false -> <<"http://localhost:8734">>;
        RawNode -> list_to_binary(RawNode)
    end.

Price =
    case os:getenv("BULBASAUR_PROCESS_PRICE") of
        false -> 1;
        RawPrice -> list_to_integer(RawPrice)
    end.

WalletPath =
    case os:getenv("HB_KEY") of
        false -> <<"bulbasaur-wallet.json">>;
        RawWalletPath -> list_to_binary(RawWalletPath)
    end.

UserWalletPath =
    case os:getenv("BULBASAUR_USER_WALLET") of
        false -> error({missing_env, "BULBASAUR_USER_WALLET"});
        RawUserWalletPath -> list_to_binary(RawUserWalletPath)
    end.

LedgerProcPath =
    case os:getenv("BULBASAUR_LEDGER_PROCESS_FILE") of
        false -> <<"priv/bulbasaur-ledger-process.term">>;
        RawLedgerProcPath -> list_to_binary(RawLedgerProcPath)
    end.

HostWallet = hb:wallet(WalletPath).
UserWallet = hb:wallet(UserWalletPath).
UserAddress = hb_util:human_id(ar_wallet:to_address(UserWallet)).
SchedulerLocation = hb_util:human_id(ar_wallet:to_address(HostWallet)).
Opts = #{
    priv_wallet => HostWallet,
    <<"priv-wallet">> => HostWallet,
    operator => SchedulerLocation,
    <<"operator">> => SchedulerLocation,
    prometheus => false,
    <<"prometheus">> => false
}.
UserOpts = #{
    priv_wallet => UserWallet,
    <<"priv-wallet">> => UserWallet,
    prometheus => false,
    <<"prometheus">> => false
}.

{ok, LedgerProcBin} = file:read_file(LedgerProcPath).
LedgerProc = binary_to_term(LedgerProcBin).
LedgerProcessID = hb_util:human_id(hb_message:id(LedgerProc, signed, Opts)).
LedgerRoute = <<"/", LedgerProcessID/binary, "~process@1.0">>.
LedgerBalancePath = <<LedgerRoute/binary, "/now/balance/", UserAddress/binary>>.

{ok, InitialBalance} = hb_http:get(Node, LedgerBalancePath, Opts).
true = InitialBalance >= Price.

{ok, LuaModule} = file:read_file("scripts/bulbasaur-process.lua").
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
    ).
ProcID = hb_util:human_id(hb_message:id(Proc, all, Opts)).
{ok, _ProcScheduleRes} = hb_http:post(Node, <<"/schedule">>, Proc, Opts).

ScheduledMessage =
    hb_message:commit(
        #{
            <<"target">> => ProcID,
            <<"type">> => <<"Message">>,
            <<"action">> => <<"Ping">>,
            <<"test-label">> => <<"SPEND IMPORTED BALANCE TEST">>
        },
        Opts
    ).
{ok, _MsgScheduleRes} =
    hb_http:post(Node, <<ProcID/binary, "/schedule">>, ScheduledMessage, Opts).

ComputeReq =
    hb_message:commit(
        #{
            <<"path">> => <<"/", ProcID/binary, "~process@1.0/compute">>,
            <<"slot">> => 0
        },
        UserOpts
    ).
{ok, ComputeRes} = hb_http:get(Node, ComputeReq, UserOpts).
<<"bulbasaur-deployed-process-ok">> =
    hb_ao:get(<<"results/output/body">>, ComputeRes, Opts).

{ok, FinalBalance} = hb_http:get(Node, LedgerBalancePath, Opts).
ExpectedFinalBalance = InitialBalance - Price.
ExpectedFinalBalance = FinalBalance.

io:format(
    "Spent imported Bulbasaur balance on process compute~n"
    "Node: ~s~n"
    "Wallet: ~s~n"
    "Ledger: ~s~n"
    "Process: ~s~n"
    "Initial balance: ~p~n"
    "Price: ~p~n"
    "Final balance: ~p~n",
    [
        Node,
        UserAddress,
        LedgerProcessID,
        ProcID,
        InitialBalance,
        Price,
        FinalBalance
    ]
).
