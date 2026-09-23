--- Проверки размыкателя: замкнут, разомкнут, полуоткрыт.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g, ctx = helper.group('tnt.retry.breaker', 'tnt.retry.breaker')

--- Размыкатель с мелкими порогами: проверке незачем звать двадцать раз.
---@param overrides table|nil
---@return TntRetryBreaker
local function breaker_of(overrides)
    local opts = { name = 'etcd', window = 4, min_calls = 2, reset_timeout = 30 }

    for key, value in pairs(overrides or {}) do
        opts[key] = value
    end

    return ctx.module.new(opts)
end

--- Записывает подряд несколько отказов сервера.
---@param breaker TntRetryBreaker
---@param times integer
local function refuse(breaker, times)
    for _ = 1, times do
        breaker:record(false, 'сеть пропала')
    end
end

--- Разомкнутый размыкатель, доживший до пробы.
---@param overrides table|nil
---@return TntRetryBreaker
local function probing(overrides)
    local breaker = breaker_of(overrides)

    refuse(breaker, 2)
    ctx.clock.advance(30)

    return breaker
end

g.test_fresh_breaker_is_closed_and_lets_everything_through = function()
    local breaker = ctx.module.new()

    t.assert_equals(breaker:state(), 'closed')
    t.assert_equals(breaker:allow(), true)
    t.assert_equals(breaker.name, 'служба')
    t.assert_equals(breaker.window, 20)
    t.assert_equals(breaker.min_calls, 10)
    t.assert_equals(breaker.threshold, 0.5)
    t.assert_equals(breaker.reset_timeout, 30)
    t.assert_equals(breaker.probes, 1)
end

g.test_breaker_waits_for_enough_outcomes_before_judging = function()
    local breaker = breaker_of({ min_calls = 3 })

    refuse(breaker, 2)
    t.assert_equals(breaker:state(), 'closed')

    -- Два отказа из двух — это не доля, это совпадение; третий делает долю.
    refuse(breaker, 1)
    t.assert_equals(breaker:state(), 'open')
end

g.test_breaker_opens_when_failures_reach_the_threshold = function()
    local breaker = breaker_of()

    refuse(breaker, 2)

    t.assert_equals(breaker:state(), 'open')
    t.assert_equals(ctx.logged('размыкатель разомкнут'), true)
end

g.test_refusal_of_the_server_itself_does_not_open_the_circuit = function()
    -- «Неверный пароль» значит, что сервер жив, отвечает и разобрал
    -- запрос. Размыкать цепь от чужой опечатки — уронить всех остальных.
    local breaker = breaker_of()

    for _ = 1, 10 do
        breaker:record(false, 'неверный пароль')
    end

    t.assert_equals(breaker:state(), 'closed')
    t.assert_equals(breaker:status().failures, 0)
end

g.test_breaker_takes_its_own_notion_of_a_server_fault = function()
    local breaker = breaker_of({
        retriable = function(err)
            return err == 'наш отказ'
        end,
    })

    refuse(breaker, 10)
    t.assert_equals(breaker:state(), 'closed')

    breaker:record(false, 'наш отказ')
    breaker:record(false, 'наш отказ')
    t.assert_equals(breaker:state(), 'open')
end

g.test_open_breaker_refuses_at_once_and_says_when_to_come_back = function()
    local breaker = breaker_of()

    refuse(breaker, 2)

    local allowed, refusal = breaker:allow()

    t.assert_equals(allowed, false)
    t.assert_str_contains(refusal, 'etcd не отвечает')
    t.assert_str_contains(refusal, 'проба через 30.0 с')

    ctx.clock.advance(18)
    local _, later = breaker:allow()
    t.assert_str_contains(later, 'проба через 12.0 с')
end

g.test_silence_runs_out_and_the_breaker_lets_a_probe_through = function()
    local breaker = probing()

    t.assert_equals(breaker:state(), 'half_open')
    t.assert_equals(breaker:allow(), true)

    -- Проба одна: второй вызов ждёт, чем кончилась первая.
    local allowed, refusal = breaker:allow()
    t.assert_equals(allowed, false)
    t.assert_str_contains(refusal, 'etcd ещё проверяется')
end

g.test_successful_probe_closes_the_circuit = function()
    local breaker = probing({ probes = 2 })

    -- Проб заказано две: столько вызовов и пускается, пока цепь проверяется.
    t.assert_equals(breaker:allow(), true)
    t.assert_equals(breaker:allow(), true)

    local allowed, refusal = breaker:allow()
    t.assert_equals(allowed, false)
    t.assert_str_contains(refusal, 'etcd ещё проверяется')

    breaker:record(true, nil)

    t.assert_equals(breaker:state(), 'closed')
    t.assert_equals(breaker:allow(), true)
    t.assert_equals(ctx.logged('размыкатель замкнут'), true)
end

g.test_probe_does_not_come_before_the_silence_is_over = function()
    local breaker = breaker_of()

    refuse(breaker, 2)
    ctx.clock.advance(29.5)

    -- Полсекунды до срока — это ещё срок: цепь молчит.
    t.assert_equals(breaker:state(), 'open')
    t.assert_almost_equals(breaker:silence_left(), 0.5, 1e-9)
end

g.test_call_tells_the_action_that_it_is_the_only_attempt = function()
    local breaker = breaker_of()
    local seen

    breaker:call(function(context)
        seen = context

        return 'готово'
    end)

    t.assert_equals(seen, { attempt = 1, elapsed = 0 })
end

g.test_failed_probe_opens_the_circuit_again_for_the_whole_silence = function()
    local breaker = probing()

    breaker:allow()
    breaker:record(false, 'сеть пропала')

    t.assert_equals(breaker:state(), 'open')

    local _, refusal = breaker:allow()
    t.assert_str_contains(refusal, 'проба через 30.0 с')
end

g.test_overdue_silence_lets_the_probe_through_and_is_never_negative = function()
    local breaker = breaker_of()

    refuse(breaker, 2)
    ctx.clock.advance(31)

    -- Секунда сверх срока — это тоже «срок вышел»: проба не привязана
    -- к тому, позвали ли размыкатель ровно в назначенный миг.
    t.assert_equals(breaker:silence_left(), 0)
    t.assert_equals(breaker:state(), 'half_open')
end

g.test_window_forgets_the_oldest_outcome_when_it_wraps = function()
    -- Порог единица: цепь не размыкается, и видно само окно.
    local breaker = breaker_of({ window = 3, min_calls = 3, threshold = 1 })

    breaker:record(false, 'сеть пропала')
    breaker:record(true, nil)
    breaker:record(false, 'сеть пропала')
    t.assert_equals(breaker:status(), {
        name = 'etcd',
        state = 'closed',
        calls = 3,
        failures = 2,
        threshold = 1,
        min_calls = 3,
        probes_left = 0,
        silence_left = 0,
    })

    -- Круг замкнулся: самый старый исход был отказом и списывается.
    breaker:record(true, nil)
    t.assert_equals(breaker:status().calls, 3)
    t.assert_equals(breaker:status().failures, 1)

    -- А этот был удачей: списывать нечего.
    breaker:record(false, 'сеть пропала')
    t.assert_equals(breaker:status().calls, 3)
    t.assert_equals(breaker:status().failures, 2)
end

g.test_outcomes_from_before_the_break_are_forgotten = function()
    local breaker = probing()

    t.assert_equals(breaker:status().calls, 0)
    t.assert_equals(breaker:status().failures, 0)
end

g.test_status_shows_how_long_the_circuit_stays_silent = function()
    local breaker = breaker_of()

    refuse(breaker, 2)
    ctx.clock.advance(11)

    local status = breaker:status()

    t.assert_equals(status.state, 'open')
    t.assert_almost_equals(status.silence_left, 19, 1e-9)
end

g.test_call_goes_through_a_closed_circuit_and_gives_back_the_value = function()
    local breaker = breaker_of()

    local value, err = breaker:call(function()
        return 'готово'
    end)

    t.assert_equals(value, 'готово')
    t.assert_equals(err, nil)
    t.assert_equals(breaker:status().calls, 1)
    t.assert_equals(breaker:status().failures, 0)
end

g.test_call_through_an_open_circuit_never_reaches_the_action = function()
    local breaker = breaker_of()
    local reached = false

    refuse(breaker, 2)

    local value, err = breaker:call(function()
        reached = true

        return 'готово'
    end)

    t.assert_equals(reached, false)
    t.assert_equals(value, nil)
    t.assert_str_contains(err, 'размыкатель разомкнут')
end

g.test_call_remembers_the_refusal_of_the_action = function()
    local breaker = breaker_of()

    breaker:call(function()
        return nil, 'сеть пропала'
    end)
    breaker:call(function()
        error('сеть пропала')
    end)

    t.assert_equals(breaker:state(), 'open')
end

g.test_reset_returns_the_breaker_to_how_it_came_out_of_the_box = function()
    local breaker = breaker_of()

    refuse(breaker, 2)
    t.assert_equals(breaker:state(), 'open')

    breaker:reset()

    t.assert_equals(breaker:state(), 'closed')
    t.assert_equals(breaker:allow(), true)
    t.assert_equals(breaker:status().calls, 0)
    t.assert_equals(breaker:status().failures, 0)
    t.assert_equals(breaker:status().silence_left, 0)
end

g.test_typo_in_the_settings_is_thrown_at_the_line_that_makes_the_breaker = function()
    -- `{ treshold = 0.1 }` иначе молча дал бы порог по умолчанию — половину.
    t.assert_equals(
        helper.thrown(ctx.module.new, { treshold = 0.1 }),
        'caller:1: настройки размыкателя: ключа «treshold» нет, есть min_calls, name, probes, reset_timeout, '
            .. 'retriable, threshold, window'
    )
    t.assert_equals(
        helper.thrown(ctx.module.new, 'etcd'),
        'caller:1: настройки размыкателя — таблица, а не строка'
    )
end

g.test_bad_values_are_thrown_before_the_first_call = function()
    -- Прежде строка вместо числа бросала на первом же вызове, посреди
    -- работы, а не на строке, где размыкатель заводят.
    local cases = {
        { { name = 5 }, 'настройка name — имя службы строкой, а пришло: 5' },
        {
            { threshold = 0 },
            'настройка threshold — доля больше 0 и не больше 1, а пришло: 0',
        },
        {
            { threshold = 1.5 },
            'настройка threshold — доля больше 0 и не больше 1, а пришло: 1.5',
        },
        {
            { threshold = false },
            'настройка threshold — доля больше 0 и не больше 1, а пришло: false',
        },
        { { window = 0 }, 'настройка window — целое число от 1, а пришло: 0' },
        { { min_calls = 2.5 }, 'настройка min_calls — целое число от 1, а пришло: 2.5' },
        {
            { reset_timeout = 0 },
            'настройка reset_timeout — срок в секундах больше нуля, а пришло: 0',
        },
        {
            { reset_timeout = 'минута' },
            'настройка reset_timeout — срок в секундах больше нуля, а пришло: минута',
        },
        { { probes = 0 }, 'настройка probes — целое число от 1, а пришло: 0' },
        { { retriable = 'да' }, 'настройка retriable должна быть функцией' },
    }

    for _, case in ipairs(cases) do
        t.assert_equals(
            helper.thrown(ctx.module.new, case[1]),
            'caller:1: настройки размыкателя: ' .. case[2]
        )
    end
end

g.test_window_smaller_than_min_calls_never_opens_and_is_refused = function()
    -- Окно помнит четыре исхода, решения ждут десяти: такая цепь
    -- не разомкнётся, как бы служба ни лежала.
    t.assert_equals(
        helper.thrown(ctx.module.new, { window = 4 }),
        'caller:1: настройки размыкателя: настройка min_calls больше window: окно не вместит столько исходов, '
            .. 'и цепь не разомкнётся'
    )

    -- Вровень — годится: окно набирается и решает.
    local breaker = ctx.module.new({ window = 2, min_calls = 2 })

    refuse(breaker, 2)
    t.assert_equals(breaker:state(), 'open')
end

g.test_fitting_settings_are_taken_as_given = function()
    local judge = function()
        return true
    end
    local breaker = ctx.module.new({
        name = 'склад',
        threshold = 1,
        window = 1,
        min_calls = 1,
        reset_timeout = 0.5,
        probes = 3,
        retriable = judge,
    })

    t.assert_equals(breaker.name, 'склад')
    t.assert_equals(breaker.threshold, 1)
    t.assert_equals(breaker.window, 1)
    t.assert_equals(breaker.min_calls, 1)
    t.assert_equals(breaker.reset_timeout, 0.5)
    t.assert_equals(breaker.probes, 3)
    t.assert_is(breaker.retriable, judge)
end

g.test_null_from_yaml_or_json_means_the_default = function()
    -- `box.NULL` равен nil в сравнении и прошёл бы проверку судьи, а звать
    -- его нельзя: он значит «настройки нет», и судит умолчание.
    local breaker = ctx.module.new({ retriable = box.NULL, window = box.NULL })

    t.assert_is(breaker.retriable, helper.module('tnt.retry.classify').of)
    t.assert_equals(breaker.window, 20)
end
