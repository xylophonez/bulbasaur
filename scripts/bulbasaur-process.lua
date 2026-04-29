function compute(base, assignment, opts)
    base.count = (base.count or 0) + 1
    base.results = {
        output = {
            body = "bulbasaur-deployed-process-ok",
            action = assignment.body.action or "unknown"
        }
    }
    return base
end
