SubmitURL =
    case os:getenv("SUBMIT_URL") of
        false ->
            case os:getenv("LEGACY_MU_URL") of
                false -> <<"https://mu.ao-testnet.xyz">>;
                RawLegacyMUURL -> list_to_binary(RawLegacyMUURL)
            end;
        RawSubmitURL -> list_to_binary(RawSubmitURL)
    end.

Token =
    case os:getenv("TOKEN") of
        false -> <<"0syT13r0s0tgPmIed95bJnuSqaD29HQNN8D3ElLSrsc">>;
        RawToken -> list_to_binary(RawToken)
    end.

Ledger =
    case os:getenv("LEDGER") of
        false -> <<"aqu6pW4GemwbDguS-rtCEBT_CJqsLYAWcmAULnZR-cE">>;
        RawLedger -> list_to_binary(RawLedger)
    end.

DepositAddress =
    case os:getenv("DEPOSIT_ADDRESS") of
        false ->
            case os:getenv("RECIPIENT") of
                false -> Ledger;
                RawRecipient -> list_to_binary(RawRecipient)
            end;
        RawDepositAddress -> list_to_binary(RawDepositAddress)
    end.

Quantity =
    case os:getenv("QUANTITY") of
        false -> <<"1">>;
        RawQuantity -> list_to_binary(RawQuantity)
    end.

WalletPath =
    case os:getenv("WALLET") of
        false -> error({missing_env, "WALLET"});
        RawWalletPath -> list_to_binary(RawWalletPath)
    end.

Submit =
    case os:getenv("SUBMIT") of
        false -> true;
        "false" -> false;
        "0" -> false;
        _ -> true
    end.

OutPath =
    case os:getenv("OUT") of
        false -> false;
        RawOutPath -> RawOutPath
    end.

Wallet = hb:wallet(WalletPath).
Sender = hb_util:human_id(ar_wallet:to_address(Wallet)).
LocalRecipient =
    case os:getenv("LOCAL_RECIPIENT") of
        false -> Sender;
        RawLocalRecipient -> list_to_binary(RawLocalRecipient)
    end.
Target = hb_util:native_id(Token).
Anchor = crypto:strong_rand_bytes(32).
Tags = [
    {<<"Data-Protocol">>, <<"ao">>},
    {<<"Variant">>, <<"ao.TN.1">>},
    {<<"Type">>, <<"Message">>},
    {<<"Content-Type">>, <<"text/plain">>},
    {<<"SDK">>, <<"bulbasaur">>},
    {<<"Action">>, <<"Transfer">>},
    {<<"Recipient">>, DepositAddress},
    {<<"Quantity">>, Quantity},
    {<<"X-HB-Recipient">>, LocalRecipient}
].
Unsigned = ar_bundles:new_item(Target, Anchor, Tags, <<"bulbasaur">>).
Signed = ar_bundles:sign_item(Unsigned, Wallet).
true = ar_bundles:verify_item(Signed).
Body = ar_bundles:serialize(Signed).
MessageID = hb_util:human_id(ar_bundles:id(Signed, signed)).
URL = SubmitURL.

io:format(
    "Submitting direct AO transfer~n"
    "Submit URL: ~s~n"
    "Token: ~s~n"
    "Ledger: ~s~n"
    "Deposit address: ~s~n"
    "Sender: ~s~n"
    "Local recipient: ~s~n"
    "Quantity: ~s~n"
    "Message: ~s~n",
    [SubmitURL, Token, Ledger, DepositAddress, Sender, LocalRecipient, Quantity, MessageID]
).

case OutPath of
    false -> ok;
    _ -> ok = file:write_file(OutPath, Body)
end.

case Submit of
    true ->
        application:ensure_all_started(inets),
        application:ensure_all_started(ssl),
        Request = {
            binary_to_list(URL),
            [{"accept", "application/json"}],
            "application/octet-stream",
            Body
        },
        Result = httpc:request(post, Request, [], [{body_format, binary}]),
        io:format("Submit result: ~p~n", [Result]);
    false ->
        io:format("Submit result: dry-run; local ANS-104 verification passed~n")
end.
