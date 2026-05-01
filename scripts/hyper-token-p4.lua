--- An extension to the `hyper-token.lua` script, for execution with the
--- `lua@5.3a` device. This script adds the ability for an `admin' account to
--- charge a user's account. This is useful for allowing a node operator to
--- collect fees from users, if they are running in a trusted execution
--- environment.
--- 
--- This script must be added as after the `hyper-token.lua` script in the
--- `process-definition`s `script` field.

local function p4_normalize_int(value)
    local num
    if type(value) == "string" then
        if string.find(value, "%.") then
            return nil
        end
        num = tonumber(value)
    elseif type(value) == "number" then
        num = value
    else
        return nil
    end

    if not num or num ~= math.floor(num) then
        return nil
    end
    return num
end

local function validate_admin_request(base, assignment)
    local admin = base.admin
    local req = assignment.body
    local _, committers = ao.resolve(req, "committers")
    ao.event({ "debug_charge", { "Validating admin requester: ", {
        admin = admin,
        committers = committers,
        request = req,
    } }})

    if count_common(committers, admin) ~= 1 then
        return "error", base
    end

    local status, res, request = validate_request(base, assignment)
    if status ~= "ok" then
        return status, res
    end

    return "ok", res, request
end

-- Process an `admin' charge request:
-- 1. Verify the sender's identity.
-- 2. Ensure that the quantity and account are present in the request.
-- 3. Debit the source account.
-- 4. Increment the balance of the recipient account.
function charge(base, assignment)
    ao.event({ "debug_charge", { "Charging", { assignment = assignment } } })

    -- Verify that the request is signed by the admin.
    local status, res, request = validate_admin_request(base, assignment)
    if status ~= "ok" then
        return status, res
    end

    -- Ensure that the quantity and account are present in the request.
    if not request.quantity or not request.account then
        ao.event({ "Failure: Quantity or account not found in request.",
            { request = request } })
        base.result = {
            status = "error",
            error = "Quantity or account not found in request."
        }
        return "ok", base
    end

    -- Debit the source. Note: We do not check the source balance here, because
    -- the node is capable of debiting the source at-will -- even it puts the
    -- source into debt. This is important because the node may estimate the
    -- cost of an execution at lower than its actual cost. Subsequently, the
    -- ledger should at least debit the source, even if the source may not
    -- deposit to restore this balance.
    ao.event({ "Debit request validated: ", { assignment = assignment } })
    base.balance = base.balance or {}
    base.balance[request.account] =
        (base.balance[request.account] or 0) - request.quantity

    -- Increment the balance of the recipient account.
    base.balance[request.recipient] =
        (base.balance[request.recipient] or 0) + request.quantity

    ao.event("debug_charge", { "Charge processed: ", { balances = base.balance } })
    return "ok", base
end

function reserve(base, assignment)
    ao.event({ "debug_reserve", { "Reserving", { assignment = assignment } } })

    local status, res, request = validate_admin_request(base, assignment)
    if status ~= "ok" then
        return status, res
    end

    local reservation_id = request["reservation-id"]
    local quantity = p4_normalize_int(request.quantity)
    if not reservation_id or not request.account or not request.recipient or not quantity then
        base.result = {
            status = "error",
            error = "reservation-id, quantity, account, and recipient are required."
        }
        return "error", base
    end

    base.balance = base.balance or {}
    base.reservations = base.reservations or {}
    if base.reservations[reservation_id] then
        base.result = {
            status = "error",
            error = "Reservation already exists.",
            ["reservation-id"] = reservation_id
        }
        return "error", base
    end

    local balance = base.balance[request.account] or 0
    if balance < quantity then
        base.result = {
            status = "error",
            error = "Insufficient funds.",
            account = request.account,
            quantity = quantity,
            balance = balance
        }
        return "error", base
    end

    base.balance[request.account] = balance - quantity
    base.reservations[reservation_id] = {
        status = "reserved",
        account = request.account,
        recipient = request.recipient,
        quantity = quantity,
        request = request.request
    }
    base.result = {
        status = "ok",
        ["reservation-id"] = reservation_id,
        quantity = quantity
    }
    return "ok", base
end

function release(base, assignment)
    ao.event({ "debug_release", { "Releasing", { assignment = assignment } } })

    local status, res, request = validate_admin_request(base, assignment)
    if status ~= "ok" then
        return status, res
    end

    local reservation_id = request["reservation-id"]
    base.balance = base.balance or {}
    base.reservations = base.reservations or {}
    local reservation = base.reservations[reservation_id]
    if not reservation or reservation.status ~= "reserved" then
        if reservation and reservation.status == "released" then
            base.result = {
                status = "ok",
                ["reservation-id"] = reservation_id,
                quantity = reservation.quantity,
                recipient = reservation.recipient
            }
            return "ok", base
        end
        base.result = {
            status = "error",
            error = "Reservation is not releasable.",
            ["reservation-id"] = reservation_id
        }
        return "error", base
    end

    local recipient = request.recipient or reservation.recipient
    base.balance[recipient] = (base.balance[recipient] or 0) + reservation.quantity
    reservation.status = "released"
    reservation.recipient = recipient
    base.result = {
        status = "ok",
        ["reservation-id"] = reservation_id,
        quantity = reservation.quantity,
        recipient = recipient
    }
    return "ok", base
end

function refund(base, assignment)
    ao.event({ "debug_refund", { "Refunding", { assignment = assignment } } })

    local status, res, request = validate_admin_request(base, assignment)
    if status ~= "ok" then
        return status, res
    end

    local reservation_id = request["reservation-id"]
    base.balance = base.balance or {}
    base.reservations = base.reservations or {}
    local reservation = base.reservations[reservation_id]
    if not reservation or reservation.status ~= "reserved" then
        if reservation and reservation.status == "refunded" then
            base.result = {
                status = "ok",
                ["reservation-id"] = reservation_id,
                quantity = reservation.quantity,
                account = reservation.account
            }
            return "ok", base
        end
        base.result = {
            status = "error",
            error = "Reservation is not refundable.",
            ["reservation-id"] = reservation_id
        }
        return "error", base
    end

    base.balance[reservation.account] =
        (base.balance[reservation.account] or 0) + reservation.quantity
    reservation.status = "refunded"
    base.result = {
        status = "ok",
        ["reservation-id"] = reservation_id,
        quantity = reservation.quantity,
        account = reservation.account
    }
    return "ok", base
end
