--- Проверки бюджета повторов: ведро жетонов и его границы.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g, ctx = helper.group('tnt.retry.budget', 'tnt.retry.budget')

--- Записывает подряд несколько одинаковых исходов.
---@param bucket table
---@param ok boolean
---@param times integer
local function record(bucket, ok, times)
    for _ = 1, times do
        bucket:record(ok)
    end
end

g.test_fresh_bucket_is_full_and_allows_repeats = function()
    local bucket = ctx.module.new()

    t.assert_equals(bucket.tokens, 100)
    t.assert_equals(bucket.max, 100)
    t.assert_equals(bucket.ratio, 0.1)
    t.assert_equals(bucket:allow(), true)
end

g.test_bucket_takes_its_size_and_ratio_from_the_caller = function()
    local bucket = ctx.module.new({ tokens = 10, ratio = 0.5 })

    t.assert_equals(bucket.tokens, 10)
    t.assert_equals(bucket.max, 10)
    t.assert_equals(bucket.ratio, 0.5)
end

g.test_refusal_takes_a_token_and_success_gives_back_a_share = function()
    local bucket = ctx.module.new({ tokens = 10, ratio = 0.25 })

    bucket:record(false)
    t.assert_equals(bucket.tokens, 9)

    bucket:record(true)
    t.assert_equals(bucket.tokens, 9.25)
end

g.test_repeats_stop_at_half_the_bucket = function()
    local bucket = ctx.module.new({ tokens = 10 })

    record(bucket, false, 4)
    t.assert_equals(bucket.tokens, 6)
    t.assert_equals(bucket:allow(), true)

    -- Ровно половина — это уже не «больше половины»: край считается занятым.
    bucket:record(false)
    t.assert_equals(bucket.tokens, 5)
    t.assert_equals(bucket:allow(), false)
end

g.test_bucket_never_goes_below_empty = function()
    local bucket = ctx.module.new({ tokens = 2 })

    record(bucket, false, 5)

    t.assert_equals(bucket.tokens, 0)
    t.assert_equals(bucket:allow(), false)
end

g.test_bucket_never_overflows = function()
    local bucket = ctx.module.new({ tokens = 2, ratio = 1 })

    record(bucket, true, 5)

    t.assert_equals(bucket.tokens, 2)
end

g.test_successes_refill_the_bucket_and_bring_repeats_back = function()
    local bucket = ctx.module.new({ tokens = 10, ratio = 0.1 })

    record(bucket, false, 6)
    t.assert_equals(bucket:allow(), false)

    -- Одна десятая жетона за удачу: чтобы вернуть один жетон, нужно
    -- десять удачных вызовов — вот и весь смысл соотношения.
    record(bucket, true, 10)
    t.assert_almost_equals(bucket.tokens, 5, 1e-9)
    t.assert_equals(bucket:allow(), false)

    record(bucket, true, 10)
    t.assert_almost_equals(bucket.tokens, 6, 1e-9)
    t.assert_equals(bucket:allow(), true)
end

g.test_reset_fills_the_bucket_back_to_the_brim = function()
    local bucket = ctx.module.new({ tokens = 10 })

    record(bucket, false, 8)
    t.assert_equals(bucket:allow(), false)

    bucket:reset()

    t.assert_equals(bucket.tokens, 10)
    t.assert_equals(bucket:allow(), true)
end

g.test_status_tells_everything_the_bucket_knows = function()
    local bucket = ctx.module.new({ tokens = 4, ratio = 0.2 })

    record(bucket, false, 3)

    t.assert_equals(bucket:status(), { tokens = 1, max = 4, ratio = 0.2, allowed = false })
end

g.test_typo_in_the_settings_is_thrown_at_the_line_that_makes_the_bucket = function()
    -- `{ token = 4 }` иначе молча дал бы ведро на сто жетонов.
    t.assert_equals(
        helper.thrown(ctx.module.new, { token = 4 }),
        'caller:1: настройка budget: ключа «token» нет, есть ratio, tokens'
    )
    t.assert_equals(
        helper.thrown(ctx.module.new, 'много'),
        'caller:1: настройка budget — таблица, а не строка'
    )
end

g.test_size_of_the_bucket_is_a_finite_number_above_zero = function()
    local expected =
        'caller:1: настройка budget.tokens — конечное число больше нуля, а пришло: '

    t.assert_equals(helper.thrown(ctx.module.new, { tokens = 0 }), expected .. '0')
    t.assert_equals(helper.thrown(ctx.module.new, { tokens = -1 }), expected .. '-1')
    t.assert_equals(helper.thrown(ctx.module.new, { tokens = '10' }), expected .. '10')

    -- `false` — не «умолчание»: заменить его молча значило бы спрятать
    -- ошибку того, кто его написал.
    t.assert_equals(helper.thrown(ctx.module.new, { tokens = false }), expected .. 'false')

    -- Половина бесконечности — та же бесконечность: ведро без дна
    -- не пустило бы ни одного повтора.
    t.assert_equals(helper.thrown(ctx.module.new, { tokens = math.huge }), expected .. 'inf')
    t.assert_equals(ctx.module.new({ tokens = 0.5 }).max, 0.5)
end

g.test_refund_is_a_share_above_zero_and_up_to_a_whole_token = function()
    local expected =
        'caller:1: настройка budget.ratio — доля больше 0 и не больше 1, а пришло: '

    -- Удача, не возвращающая ничего, опустошает ведро навсегда.
    t.assert_equals(helper.thrown(ctx.module.new, { ratio = 0 }), expected .. '0')
    t.assert_equals(helper.thrown(ctx.module.new, { ratio = 1.5 }), expected .. '1.5')
    t.assert_equals(ctx.module.new({ ratio = 1 }).ratio, 1)
end

g.test_complaint_tells_what_is_wrong_without_throwing = function()
    t.assert_equals(ctx.module.complaint({ tokens = 4, ratio = 1 }), nil)
    t.assert_equals(ctx.module.complaint({}), nil)
    t.assert_equals(
        ctx.module.complaint({ tokens = 4, ratio = 0 }),
        'настройка budget.ratio — доля больше 0 и не больше 1, а пришло: 0'
    )
end

g.test_null_from_yaml_or_json_means_the_default = function()
    -- `null` из YAML и JSON приходит `box.NULL`, а он истинен: отданный
    -- вместо умолчания, он стал бы размером ведра.
    local bucket = ctx.module.new({ tokens = box.NULL, ratio = box.NULL })

    t.assert_equals(bucket.max, 100)
    t.assert_equals(bucket.tokens, 100)
    t.assert_equals(bucket.ratio, 0.1)
end
