--- Проверки отступа: степень, потолок и разброс.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g, ctx = helper.group('tnt.retry.backoff', 'tnt.retry.backoff')

--- Обычные настройки отступа: первая пауза в десятую долю секунды,
--- удвоение и потолок в пять секунд.
---@param jitter number|string|nil
---@return table
local function opts(jitter)
    return { base = 0.1, factor = 2, max = 5, jitter = jitter or 0 }
end

g.test_pause_doubles_with_every_attempt = function()
    t.assert_equals(ctx.module.raw(1, opts()), 0.1)
    t.assert_equals(ctx.module.raw(2, opts()), 0.2)
    t.assert_equals(ctx.module.raw(3, opts()), 0.4)
    t.assert_equals(ctx.module.raw(4, opts()), 0.8)
end

g.test_pause_never_climbs_above_the_cap = function()
    -- 0.1 * 2^6 — это 6.4 секунды, и потолок обязан их срезать.
    t.assert_equals(ctx.module.raw(7, opts()), 5)
    t.assert_equals(ctx.module.raw(70, opts()), 5)
end

g.test_growth_past_infinity_still_gives_the_cap = function()
    -- `2^2000` — это уже бесконечность, а `base * inf` при нулевой base
    -- дало бы NaN: паузу, которой нет и которая длится вечно.
    t.assert_equals(ctx.module.raw(2000, opts()), 5)
    t.assert_equals(ctx.module.raw(2000, { base = 0, factor = 2, max = 5 }), 5)
end

g.test_without_jitter_the_pause_is_exactly_the_power = function()
    helper.random(0)

    t.assert_equals(ctx.module.delay_for(1, opts(0)), 0.1)
    t.assert_equals(ctx.module.delay_for(3, opts(0)), 0.4)
end

g.test_full_jitter_spreads_the_pause_from_zero_to_the_power = function()
    helper.random(0)
    t.assert_equals(ctx.module.delay_for(3, opts(1)), 0)

    helper.random(0.25)
    t.assert_almost_equals(ctx.module.delay_for(3, opts(1)), 0.1, 1e-12)

    helper.random(1)
    t.assert_almost_equals(ctx.module.delay_for(3, opts(1)), 0.4, 1e-12)
end

g.test_equal_jitter_keeps_half_of_the_pause_guaranteed = function()
    helper.random(0)
    t.assert_almost_equals(ctx.module.delay_for(3, opts(0.5)), 0.2, 1e-12)

    helper.random(1)
    t.assert_almost_equals(ctx.module.delay_for(3, opts(0.5)), 0.4, 1e-12)
end

g.test_decorrelated_jitter_counts_from_the_previous_pause = function()
    local settings = opts(ctx.module.DECORRELATED)

    -- Прошлой паузы ещё нет: считается от base, верхняя граница — втрое выше.
    helper.random(0)
    t.assert_almost_equals(ctx.module.delay_for(1, settings), 0.1, 1e-12)

    helper.random(1)
    t.assert_almost_equals(ctx.module.delay_for(1, settings), 0.3, 1e-12)

    helper.random(1)
    t.assert_almost_equals(ctx.module.delay_for(1, settings, 0.5), 1.5, 1e-12)
end

g.test_decorrelated_jitter_obeys_the_cap = function()
    local settings = opts(ctx.module.DECORRELATED)

    helper.random(1)
    t.assert_equals(ctx.module.delay_for(9, settings, 2), 5)

    helper.random(0)
    t.assert_almost_equals(ctx.module.delay_for(9, settings, 2), 0.1, 1e-12)
end

g.test_decorrelated_jitter_ignores_the_attempt_number = function()
    helper.random(0.5)

    local settings = opts(ctx.module.DECORRELATED)
    local first = ctx.module.delay_for(1, settings, 0.4)
    local tenth = ctx.module.delay_for(10, settings, 0.4)

    t.assert_equals(first, tenth)
    t.assert_almost_equals(first, 0.65, 1e-12)
end

g.test_fraction_reads_the_bytes_as_a_number_from_the_highest = function()
    t.assert_equals(ctx.module.fraction('\0\0\0\0'), 0)
    t.assert_equals(ctx.module.fraction('\128\0\0\0'), 0.5)
    t.assert_equals(ctx.module.fraction('\0\0\0\1'), 1 / 2 ^ 32)
    t.assert_equals(ctx.module.fraction('\1\2'), 258 / 65536)

    -- Самые большие байты не дают единицы: доля — от нуля до единицы,
    -- не включая её, и полный разброс не выходит за расчётную паузу.
    t.assert_equals(ctx.module.fraction('\255\255\255\255'), (2 ^ 32 - 1) / 2 ^ 32)
end

g.test_chance_by_default_is_made_of_four_bytes_of_the_kernel = function()
    local asked = {}

    -- Подмена байтов ядра снимает подменённый случай: `random` снова
    -- умолчание и берёт байты у подменённого `urandom`.
    ctx.module._set_source({
        urandom = function(count)
            table.insert(asked, count)

            return ('\64'):rep(count)
        end,
    })

    -- Четыре байта 0x40 — число 0x40404040 из 2^32 возможных.
    local pause = ctx.module.delay_for(1, { base = 1, factor = 2, max = 5, jitter = 1 })

    t.assert_equals(pause, 0x40404040 / 2 ^ 32)
    t.assert_equals(asked, { 4 })
end

g.test_chance_by_default_differs_from_draw_to_draw = function()
    -- Настоящие байты ядра: пауза полного разброса лежит от нуля
    -- до расчётной, и две подряд совпадают с вероятностью 2^-32.
    ctx.module._set_source(nil)

    local settings = { base = 1, factor = 2, max = 5, jitter = 1 }
    local first = ctx.module.delay_for(1, settings)
    local second = ctx.module.delay_for(1, settings)

    t.assert_ge(first, 0)
    t.assert_lt(first, 1)
    t.assert_ge(second, 0)
    t.assert_lt(second, 1)
    t.assert_not_equals(first, second)
end
