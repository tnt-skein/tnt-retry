--- Проверки правил значений: границы включены или нет — и NaN не проходит.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g, ctx = helper.group('tnt.retry.rule', 'tnt.retry.rule')

g.test_refusal_names_the_setting_what_was_expected_and_what_came = function()
    t.assert_equals(
        ctx.module.refusal('window', 'целое число от 1', 0),
        'настройка window — целое число от 1, а пришло: 0'
    )
end

g.test_count_is_a_whole_number_from_one = function()
    local expected = 'настройка probes — целое число от 1, а пришло: '

    t.assert_equals(ctx.module.count(1, 'probes'), nil)
    t.assert_equals(ctx.module.count(3, 'probes'), nil)
    t.assert_equals(ctx.module.count(0, 'probes'), expected .. '0')
    t.assert_equals(ctx.module.count(2.5, 'probes'), expected .. '2.5')
    t.assert_equals(ctx.module.count('3', 'probes'), expected .. '3')

    -- Остаток бесконечности от деления на единицу — NaN, и её не пропускает
    -- та же проверка целого.
    t.assert_equals(ctx.module.count(math.huge, 'probes'), expected .. 'inf')
    helper.assert_starts(ctx.module.count(0 / 0, 'probes'), expected)
end

g.test_share_is_above_zero_and_up_to_one = function()
    local expected = 'настройка ratio — доля больше 0 и не больше 1, а пришло: '

    t.assert_equals(ctx.module.share(0.5, 'ratio'), nil)
    t.assert_equals(ctx.module.share(1, 'ratio'), nil)
    t.assert_equals(ctx.module.share(0, 'ratio'), expected .. '0')
    t.assert_equals(ctx.module.share(-0.5, 'ratio'), expected .. '-0.5')
    t.assert_equals(ctx.module.share(1.5, 'ratio'), expected .. '1.5')
    t.assert_equals(ctx.module.share('половина', 'ratio'), expected .. 'половина')
    helper.assert_starts(ctx.module.share(0 / 0, 'ratio'), expected)
end

g.test_seconds_are_above_zero = function()
    local expected =
        'настройка reset_timeout — срок в секундах больше нуля, а пришло: '

    t.assert_equals(ctx.module.seconds(0.5, 'reset_timeout'), nil)
    t.assert_equals(ctx.module.seconds(0, 'reset_timeout'), expected .. '0')
    t.assert_equals(ctx.module.seconds(-1, 'reset_timeout'), expected .. '-1')
    t.assert_equals(ctx.module.seconds('минута', 'reset_timeout'), expected .. 'минута')
    helper.assert_starts(ctx.module.seconds(0 / 0, 'reset_timeout'), expected)
end

g.test_callable_is_a_function_when_it_is_given_at_all = function()
    t.assert_equals(ctx.module.callable(nil, 'on_attempt'), nil)
    t.assert_equals(ctx.module.callable(print, 'on_attempt'), nil)
    t.assert_equals(
        ctx.module.callable('да', 'on_attempt'),
        'настройка on_attempt должна быть функцией'
    )
end
