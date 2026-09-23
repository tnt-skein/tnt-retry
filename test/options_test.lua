--- Проверки настроек: умолчания, слияние и отказ до первой попытки.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g, ctx = helper.group('tnt.retry.options', 'tnt.retry.options')

--- Чем начинается каждый отказ настроек повторов: пакет называет себя сам,
--- и тот, кто передаёт отказ дальше, своей приставки не ставит.
local TITLE = 'настройки повторов: '

--- Отказ, которым настройки встретили заданное.
---@param overrides any Заданное; в проверках отказа — и не таблицей
---@param instance boolean|nil
---@return string
local function refusal(overrides, instance)
    local settings, err = ctx.module.resolve(ctx.module.defaults(), overrides, instance)

    t.assert_equals(settings, nil, 'настройки приняли то, что принимать нельзя')

    return err
end

--- Принятые настройки; отказ здесь — ошибка самой проверки.
---@param overrides table
---@param instance boolean|nil
---@return table
local function accepted(overrides, instance)
    local settings, err = ctx.module.resolve(ctx.module.defaults(), overrides, instance)

    return (assert(settings, tostring(err)))
end

g.test_defaults_are_safe_and_named = function()
    local defaults = ctx.module.defaults()

    t.assert_equals(defaults.attempts, 3)
    t.assert_equals(defaults.base, 0.1)
    t.assert_equals(defaults.factor, 2)
    t.assert_equals(defaults.jitter, 1)
    t.assert_equals(defaults.max, 5)
    t.assert_equals(defaults.scope, 'default')
    t.assert_equals(defaults.deadline, nil)
    t.assert_type(defaults.retriable, 'function')
end

g.test_defaults_are_a_fresh_table_every_time = function()
    -- Общая таблица умолчаний означала бы, что экземпляр, которому
    -- поправили `max`, поправил его всем остальным.
    local first = ctx.module.defaults()

    first.max = 99

    t.assert_equals(ctx.module.defaults().max, 5)
end

g.test_given_settings_cover_the_defaults = function()
    local settings = accepted({ attempts = 7, base = 0.5, scope = 'etcd' })

    t.assert_equals(settings.attempts, 7)
    t.assert_equals(settings.base, 0.5)
    t.assert_equals(settings.scope, 'etcd')
    t.assert_equals(settings.factor, 2)
    t.assert_equals(settings.max, 5)
end

--- Настройки отдельного вызова в отказе о незнакомом ключе.
local CALL_KEYS = 'attempts, base, breaker, deadline, factor, jitter, max, on_attempt, retriable, scope'

g.test_unknown_setting_is_a_typo_and_not_an_addition = function()
    -- `attemps = 10` не применится, повторов будет три вместо десяти,
    -- и не скажет об этом никто. Рядом — всё, что бывает: опечатку видно.
    t.assert_equals(
        refusal({ attemps = 10 }),
        'настройки повторов: ключа «attemps» нет, есть ' .. CALL_KEYS
    )
    t.assert_equals(
        refusal({ attemps = 10 }, true),
        'настройки повторов: ключа «attemps» нет, есть attempts, base, breaker, budget, deadline, '
            .. 'factor, jitter, max, on_attempt, retriable, scope'
    )
end

g.test_settings_that_are_not_a_table_are_refused_by_a_pair = function()
    -- Отказ парой, как и всякий отказ настроек повторов: прежде `pairs`
    -- ронял вызов чужим текстом.
    t.assert_equals(
        refusal('attempts = 10'),
        'настройки повторов — таблица, а не строка'
    )
end

g.test_bucket_of_the_budget_belongs_to_the_instance_and_not_to_a_call = function()
    t.assert_equals(
        refusal({ budget = false }),
        'настройки повторов: ключа «budget» нет, есть ' .. CALL_KEYS
    )
    t.assert_equals(accepted({ budget = false }, true).budget, false)
    t.assert_equals(accepted({ budget = { tokens = 10 } }, true).budget, { tokens = 10 })
end

g.test_numbers_are_numbers_and_not_words = function()
    local expected = TITLE .. 'настройка base должна быть числом, а пришло: '

    t.assert_equals(refusal({ base = 'быстро' }), expected .. 'быстро')
    helper.assert_starts(
        refusal({ factor = 0 / 0 }),
        TITLE .. 'настройка factor должна быть числом'
    )
    t.assert_equals(ctx.module.check({}), nil)
    t.assert_equals(select(2, ctx.module.check({})), expected .. 'nil')
end

g.test_numbers_have_floors_that_keep_the_backoff_a_backoff = function()
    t.assert_equals(refusal({ base = -1 }), TITLE .. 'настройка base не может быть меньше 0')
    t.assert_equals(refusal({ max = -0.5 }), TITLE .. 'настройка max не может быть меньше 0')

    -- Множитель меньше единицы сокращает паузу с каждой попыткой:
    -- это не отступ, а разгон лавины.
    t.assert_equals(
        refusal({ factor = 0.5 }),
        TITLE .. 'настройка factor не может быть меньше 1'
    )
    t.assert_equals(accepted({ factor = 1 }).factor, 1)
end

g.test_cap_below_the_first_pause_is_a_contradiction = function()
    t.assert_equals(
        refusal({ base = 2, max = 1 }),
        TITLE .. 'настройка max меньше base: потолок ниже первой же паузы'
    )

    -- Вровень — не ниже: потолок, равный первой паузе, значит «ровно
    -- столько и жди», и это осмысленная настройка.
    t.assert_equals(accepted({ base = 5, max = 5 }).max, 5)
end

g.test_attempts_are_whole_and_start_from_one = function()
    local expected = TITLE .. 'настройка attempts — целое число от 1, а пришло: '

    t.assert_equals(refusal({ attempts = 0 }), expected .. '0')
    t.assert_equals(refusal({ attempts = 2.5 }), expected .. '2.5')
    t.assert_equals(refusal({ attempts = 'три' }), expected .. 'три')
    t.assert_equals(accepted({ attempts = 1 }).attempts, 1)
    t.assert_equals(accepted({ attempts = 2 }).attempts, 2)
end

g.test_endless_repeats_demand_a_deadline = function()
    t.assert_equals(
        refusal({ attempts = math.huge }),
        TITLE
            .. 'бесконечные повторы без срока: задайте deadline или конечный attempts'
    )
    t.assert_equals(accepted({ attempts = math.huge, deadline = 30 }).attempts, math.huge)
end

g.test_jitter_is_a_share_or_a_named_strategy = function()
    local expected = TITLE
        .. "настройка jitter — доля от 0 до 1 либо 'decorrelated', а пришло: "

    t.assert_equals(refusal({ jitter = 1.5 }), expected .. '1.5')
    t.assert_equals(refusal({ jitter = -0.1 }), expected .. '-0.1')
    t.assert_equals(refusal({ jitter = 'случайно' }), expected .. 'случайно')
    t.assert_equals(accepted({ jitter = 0 }).jitter, 0)
    t.assert_equals(accepted({ jitter = 0.5 }).jitter, 0.5)
    t.assert_equals(accepted({ jitter = 1 }).jitter, 1)
    t.assert_equals(accepted({ jitter = 'decorrelated' }).jitter, 'decorrelated')
end

g.test_jitter_of_nan_is_refused_and_not_slept_through = function()
    -- Сравнения с NaN ложны, и граница, записанная отрицанием, пропустила
    -- бы его: пауза вышла бы длиной NaN.
    helper.assert_starts(refusal({ jitter = 0 / 0 }), TITLE .. 'настройка jitter — доля от 0 до 1')
end

g.test_deadline_is_seconds_above_zero = function()
    local expected = TITLE
        .. 'настройка deadline — срок в секундах больше нуля, а пришло: '

    t.assert_equals(refusal({ deadline = 0 }), expected .. '0')
    t.assert_equals(refusal({ deadline = -3 }), expected .. '-3')
    t.assert_equals(refusal({ deadline = 'минута' }), expected .. 'минута')
    helper.assert_starts(refusal({ deadline = 0 / 0 }), expected)
    t.assert_equals(accepted({ deadline = 0.5 }).deadline, 0.5)
end

g.test_hooks_are_functions = function()
    local bare = { base = 0.1, factor = 2, max = 5, attempts = 1, jitter = 0, scope = 'x' }

    t.assert_equals(
        refusal({ retriable = 'да' }),
        TITLE .. 'настройка retriable должна быть функцией'
    )
    t.assert_equals(
        refusal({ on_attempt = 5 }),
        TITLE .. 'настройка on_attempt должна быть функцией'
    )

    -- Настройки без судьи: собрать их можно только в обход умолчаний,
    -- и встретить такое `check` обязан отказом, а не догадкой.
    t.assert_equals(
        select(2, ctx.module.check(bare)),
        TITLE .. 'настройка retriable должна быть функцией'
    )
end

g.test_breaker_is_needed_whole_and_not_merely_similar = function()
    local expected = TITLE .. 'настройка breaker — размыкатель из retry.breaker.new'

    t.assert_equals(refusal({ breaker = 5 }), expected)
    t.assert_equals(refusal({ breaker = { state = 'closed' } }), expected)
end

g.test_budget_is_a_table_of_settings_or_a_plain_no = function()
    t.assert_equals(
        refusal({ budget = 5 }, true),
        TITLE .. 'настройка budget — таблица настроек ведра либо false'
    )
end

g.test_typo_inside_the_budget_is_refused_and_not_left_to_the_default = function()
    -- `{ token = 4 }` иначе дал бы ведро на сто жетонов, и не сказал бы
    -- об этом никто.
    t.assert_equals(
        refusal({ budget = { token = 4 } }, true),
        TITLE .. 'настройка budget: ключа «token» нет, есть ratio, tokens'
    )
end

g.test_size_of_the_bucket_is_a_finite_number_above_zero = function()
    local expected = TITLE
        .. 'настройка budget.tokens — конечное число больше нуля, а пришло: '

    t.assert_equals(refusal({ budget = { tokens = 'x' } }, true), expected .. 'x')
    t.assert_equals(refusal({ budget = { tokens = 0 } }, true), expected .. '0')
    t.assert_equals(refusal({ budget = { tokens = false } }, true), expected .. 'false')

    -- Половина бесконечности — та же бесконечность, и ведро без дна
    -- не пустило бы ни одного повтора: без бюджета — это `budget = false`.
    t.assert_equals(refusal({ budget = { tokens = math.huge } }, true), expected .. 'inf')
    t.assert_equals(accepted({ budget = { tokens = 0.5 } }, true).budget, { tokens = 0.5 })
end

g.test_refund_of_the_bucket_is_a_share_above_zero = function()
    local expected = TITLE
        .. 'настройка budget.ratio — доля больше 0 и не больше 1, а пришло: '

    t.assert_equals(refusal({ budget = { ratio = 0 } }, true), expected .. '0')
    t.assert_equals(refusal({ budget = { ratio = 1.5 } }, true), expected .. '1.5')
    t.assert_equals(refusal({ budget = { ratio = 'много' } }, true), expected .. 'много')
    t.assert_equals(accepted({ budget = { ratio = 1 } }, true).budget, { ratio = 1 })
end

g.test_scope_names_the_bucket_with_a_string = function()
    t.assert_equals(
        refusal({ scope = 5 }),
        TITLE .. 'настройка scope — имя ведра строкой, а пришло: 5'
    )
end

g.test_worst_case_answers_how_long_the_pauses_can_take = function()
    -- Три попытки по умолчанию: две паузы, 0.1 и 0.2 секунды.
    t.assert_almost_equals(ctx.module.worst_case(accepted({})), 0.3, 1e-12)
    t.assert_equals(ctx.module.worst_case(accepted({ attempts = 1 })), 0)
    t.assert_almost_equals(ctx.module.worst_case(accepted({ attempts = 10 })), 21.3, 1e-9)
end

g.test_worst_case_never_promises_longer_than_the_deadline = function()
    t.assert_equals(ctx.module.worst_case(accepted({ attempts = 10, deadline = 4 })), 4)
    t.assert_equals(ctx.module.worst_case(accepted({ attempts = math.huge, deadline = 7 })), 7)
    t.assert_equals(ctx.module.worst_case({ attempts = math.huge }), math.huge)
end

g.test_null_inside_the_budget_means_the_default = function()
    t.assert_equals(accepted({ budget = { tokens = box.NULL } }, true).budget, { tokens = box.NULL })
end
