--- Bulbasaur's p4 ledger client. This keeps the stock charge path from
--- hyper-token-p4-client.lua, but also makes `~p4@1.0/balance` usable by
--- deriving the caller from the signed request when `target` is omitted.

local function balance_target(request)
    if request["target"] then
        return request["target"]
    end

    if request["request"] then
        if request["request"]["target"] then
            return request["request"]["target"]
        end

        local status, committers = ao.resolve(request["request"], "committers")
        if status == "ok" and type(committers) == "table" then
            return committers[1]
        end
    end

    return nil
end

function balance(base, request)
    local target = balance_target(request)
    if not target then
        return "ok", 0
    end

    local status, res = ao.resolve({
        path = base["ledger-path"] .. "/now/balance/" .. target
    })
    if status ~= "ok" then
        return "ok", 0
    end

    return "ok", res
end

function charge(base, request)
    ao.event("debug_charge", {
        "client starting charge",
        { request = request, base = base }
    })
    local status, res = ao.resolve({
        path = "(" .. base["ledger-path"] .. ")/push",
        method = "POST",
        body = request
    })
    ao.event("debug_charge", {
        "client received charge response",
        { status = status, res = res }
    })
    return "ok", res
end
