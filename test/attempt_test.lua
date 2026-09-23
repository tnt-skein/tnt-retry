--- Проверки одной попытки: что считается удачей, а что отказом.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g, ctx = helper.group('tnt.retry.attempt', 'tnt.retry.attempt')

--- Одна попытка; что действие узнало о ней, здесь чаще всего не важно.
---@param action fun(context: table): any, any
---@return boolean ok
---@return any value
---@return any err
local function once(action)
    return ctx.module.once(action, {})
end

g.test_successful_action_gives_its_value_and_second_return = function()
    local ok, value, err = once(function()
        return 'готово', 'мелочь'
    end)

    t.assert_equals(ok, true)
    t.assert_equals(value, 'готово')
    t.assert_equals(err, 'мелочь')
end

g.test_nil_with_reason_is_a_refusal = function()
    local ok, value, err = once(function()
        return nil, 'сеть пропала'
    end)

    t.assert_equals(ok, false)
    t.assert_equals(value, nil)
    t.assert_equals(err, 'сеть пропала')
end

g.test_false_is_a_refusal_too = function()
    local ok, _, err = once(function()
        return false, 'место кончилось'
    end)

    t.assert_equals(ok, false)
    t.assert_equals(err, 'место кончилось')
end

g.test_silent_refusal_gets_a_reason = function()
    local ok, _, err = once(function()
        return nil
    end)

    t.assert_equals(ok, false)
    t.assert_equals(err, ctx.module.NO_REASON)
    t.assert_equals(err, 'действие отказало и причины не назвало')
end

g.test_thrown_error_is_a_refusal_and_not_a_fall = function()
    local ok, value, err = once(function()
        error('сокет закрыт')
    end)

    t.assert_equals(ok, false)
    t.assert_equals(value, nil)
    t.assert_str_contains(err, 'сокет закрыт')
end

g.test_thrown_table_reaches_the_caller_whole = function()
    local thrown = { status = 503, message = 'сервер перегружен' }

    local _, _, err = once(function()
        error(thrown)
    end)

    t.assert_is(err, thrown)
end

g.test_thrown_nothing_gets_a_reason = function()
    local ok, _, err = once(function()
        error()
    end)

    t.assert_equals(ok, false)
    t.assert_equals(err, ctx.module.NO_REASON)
end

g.test_context_reaches_the_action = function()
    local seen

    ctx.module.once(function(context)
        seen = context

        return 'готово'
    end, { attempt = 7 })

    t.assert_equals(seen, { attempt = 7 })
end

g.test_named_reason_stays_as_it_was_named = function()
    t.assert_equals(ctx.module.reason('сеть пропала'), 'сеть пропала')
    t.assert_equals(ctx.module.reason(false), false)
    t.assert_equals(ctx.module.reason(nil), ctx.module.NO_REASON)
end
