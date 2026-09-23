--- Проверки фасада: экземпляр, синглтон, политика и состояние.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g, ctx = helper.group('tnt.retry', 'tnt.retry')

--- Отказ отдельного вызова с опечаткой в числе попыток.
local UNKNOWN_ATTEMPS = 'настройки повторов: ключа «attemps» нет, есть attempts, base, breaker, '
    .. 'deadline, factor, jitter, max, on_attempt, retriable, scope'

--- Отдельный экземпляр; отказ здесь — ошибка самой проверки.
---@param opts table|nil
---@return table
local function instance(opts)
    local made, err = ctx.module.new(opts)

    return (assert(made, tostring(err)))
end

g.test_parts_are_available_to_those_who_assemble_their_own = function()
    t.assert_is(ctx.module.attempt, helper.module('tnt.retry.attempt'))
    t.assert_is(ctx.module.backoff, helper.module('tnt.retry.backoff'))
    t.assert_is(ctx.module.breaker, helper.module('tnt.retry.breaker'))
    t.assert_is(ctx.module.budget, helper.module('tnt.retry.budget'))
    t.assert_is(ctx.module.classify, helper.module('tnt.retry.classify'))
    t.assert_is(ctx.module.options, helper.module('tnt.retry.options'))
    t.assert_is(ctx.module.runner, helper.module('tnt.retry.runner'))
end

g.test_shared_instance_is_one_and_the_same = function()
    t.assert_is(ctx.module.default(), ctx.module.default())
end

g.test_settings_reach_the_shared_instance_and_replace_it = function()
    local before = ctx.module.default()

    t.assert_equals(ctx.module.configure({ attempts = 7, base = 0.5 }), true)

    -- Прежний экземпляр забыт вместе со своими вёдрами: иначе `configure`
    -- посреди работы оставил бы старые вёдра с новыми настройками.
    t.assert_is_not(ctx.module.default(), before)
    t.assert_equals(ctx.module.status().attempts, 7)
    t.assert_equals(ctx.module.status().base, 0.5)
end

g.test_bad_settings_are_refused_and_the_old_ones_stay = function()
    ctx.module.configure({ attempts = 7 })

    local ok, err = ctx.module.configure({ attempts = 0 })

    t.assert_equals(ok, false)
    t.assert_equals(
        err,
        'настройки повторов: настройка attempts — целое число от 1, а пришло: 0'
    )
    t.assert_equals(ctx.module.status().attempts, 7)
end

g.test_run_repeats_through_the_shared_instance = function()
    local action, tries = helper.flaky(2, 'сервер молчит')

    local value, err = ctx.module.run(action)

    t.assert_equals(value, 'готово')
    t.assert_equals(err, nil)
    t.assert_equals(#tries, 3)
    t.assert_equals(ctx.clock.slept, { 0.1, 0.2 })
end

g.test_settings_of_a_single_call_cover_the_settings_of_the_instance = function()
    local action, tries = helper.flaky(math.huge, 'сервер молчит')

    ctx.module.run(action, { attempts = 2 })

    t.assert_equals(#tries, 2)
end

g.test_unknown_setting_of_a_call_is_refused_before_the_first_attempt = function()
    local reached = false

    local value, err = ctx.module.run(function()
        reached = true

        return 'готово'
    end, { attemps = 5 })

    t.assert_equals(reached, false)
    t.assert_equals(value, nil)
    t.assert_equals(err, UNKNOWN_ATTEMPS)
end

g.test_action_has_to_be_a_function = function()
    local value, err = ctx.module.run('сходи к серверу')

    t.assert_equals(value, nil)
    t.assert_equals(
        err,
        'повторять нечего: действие должно быть функцией, а пришло: string'
    )
end

g.test_policy_keeps_the_settings_so_calls_do_not_repeat_them = function()
    local call, err = ctx.module.policy({ attempts = 2, base = 0.5, jitter = 0 })

    t.assert_equals(err, nil)

    local action, tries = helper.flaky(math.huge, 'сервер молчит')
    local _, refusal = call(action)

    t.assert_equals(#tries, 2)
    t.assert_equals(refusal, 'сервер молчит')
    t.assert_equals(ctx.clock.slept, { 0.5 })
end

g.test_policy_refuses_bad_settings_at_once_and_not_in_the_middle_of_trouble = function()
    local call, err = ctx.module.policy({ factor = 0.5 })

    t.assert_equals(call, nil)
    t.assert_equals(
        err,
        'настройки повторов: настройка factor не может быть меньше 1'
    )
end

g.test_policy_lets_a_single_call_change_its_mind = function()
    local call = ctx.module.policy({ attempts = 5, jitter = 0 })
    local action, tries = helper.flaky(math.huge, 'сервер молчит')

    call(action, { attempts = 2 })

    t.assert_equals(#tries, 2)
    t.assert_equals(ctx.clock.slept, { 0.1 })
end

g.test_policy_refuses_unknown_settings_of_a_single_call = function()
    local call = ctx.module.policy({ attempts = 5 })

    local value, err = call(function()
        return 'готово'
    end, { attemps = 2 })

    t.assert_equals(value, nil)
    t.assert_equals(err, UNKNOWN_ATTEMPS)
end

g.test_separate_instance_has_its_own_settings_and_its_own_buckets = function()
    local own = instance({ attempts = 1, scope = 'etcd' })

    own:run(helper.flaky(math.huge, 'сервер молчит'))

    t.assert_equals(own:status().attempts, 1)
    t.assert_equals(own:status().budget.etcd.tokens, 99)
    t.assert_equals(ctx.module.status().attempts, 3)
    t.assert_equals(ctx.module.status().budget, {})
end

g.test_separate_instance_refuses_bad_settings = function()
    local made, err = ctx.module.new({ jitter = 3 })

    t.assert_equals(made, nil)
    t.assert_equals(
        err,
        "настройки повторов: настройка jitter — доля от 0 до 1 либо 'decorrelated', а пришло: 3"
    )
end

g.test_typo_in_the_bucket_is_refused_when_the_instance_is_made = function()
    -- Прежде `{ token = 4 }` молча давал ведро на сто жетонов.
    local made, err = ctx.module.new({ budget = { token = 4 } })

    t.assert_equals(made, nil)
    t.assert_equals(
        err,
        'настройки повторов: настройка budget: ключа «token» нет, есть ratio, tokens'
    )
end

g.test_bad_bucket_is_refused_before_the_first_attempt = function()
    -- Прежде строка вместо числа бросала из ведра на первом же повторе,
    -- посреди работы.
    local made, err = ctx.module.new({ budget = { tokens = 'x' } })

    t.assert_equals(made, nil)
    t.assert_equals(
        err,
        'настройки повторов: настройка budget.tokens — конечное число больше нуля, а пришло: x'
    )
    t.assert_equals(ctx.module.configure({ budget = { ratio = 2 } }), false)
end

g.test_every_receiver_gets_a_bucket_of_its_own = function()
    -- Общее ведро на процесс означало бы, что лежащий etcd отбирает
    -- повторы у здорового соседа.
    local own = instance({ attempts = 1 })

    own:run(helper.flaky(math.huge, 'сервер молчит'), { scope = 'etcd' })
    own:run(helper.flaky(math.huge, 'сервер молчит'), { scope = 'kafka' })
    own:run(helper.flaky(math.huge, 'сервер молчит'), { scope = 'kafka' })

    t.assert_equals(own:status().budget.etcd.tokens, 99)
    t.assert_equals(own:status().budget.kafka.tokens, 98)
end

g.test_budget_can_be_switched_off_altogether = function()
    local own = instance({ attempts = 60, budget = false })
    local action, tries = helper.flaky(math.huge, 'сервер молчит')

    own:run(action)

    -- Шестьдесят попыток подряд — это больше, чем отпустило бы полное
    -- ведро: оно срезало бы повторы на полусотне отказов.
    t.assert_equals(#tries, 60)
    t.assert_equals(own:status().budget, false)
end

g.test_bucket_takes_the_size_the_instance_asked_for = function()
    local own = instance({ attempts = 10, budget = { tokens = 4 } })
    local action, tries = helper.flaky(math.huge, 'сервер молчит')

    own:run(action)

    t.assert_equals(#tries, 2)
    t.assert_equals(own:status().budget.default.tokens, 2)
end

g.test_reset_fills_the_buckets_and_brings_the_repeats_back = function()
    local own = instance({ attempts = 10, budget = { tokens = 4 } })

    own:run(helper.flaky(math.huge, 'сервер молчит'))
    t.assert_equals(own:status().budget.default.allowed, false)

    own:reset()

    t.assert_equals(own:status().budget.default.tokens, 4)
    t.assert_equals(own:status().budget.default.allowed, true)
end

g.test_shared_buckets_are_refilled_the_same_way = function()
    ctx.module.configure({ attempts = 10, budget = { tokens = 4 } })
    ctx.module.run(helper.flaky(math.huge, 'сервер молчит'))

    ctx.module.reset()

    t.assert_equals(ctx.module.status().budget.default.tokens, 4)
end

g.test_status_tells_the_settings_and_how_long_the_pauses_can_take = function()
    ctx.module.configure({ attempts = 4, base = 0.2, factor = 3, jitter = 0.5, max = 9 })

    local status = ctx.module.status()

    t.assert_equals(status.attempts, 4)
    t.assert_equals(status.base, 0.2)
    t.assert_equals(status.factor, 3)
    t.assert_equals(status.jitter, 0.5)
    t.assert_equals(status.max, 9)
    t.assert_equals(status.scope, 'default')
    t.assert_equals(status.deadline, nil)
    t.assert_equals(status.breaker, nil)

    -- 0.2 + 0.6 + 1.8: три паузы на четыре попытки.
    t.assert_almost_equals(status.worst_case, 2.6, 1e-12)
end

g.test_status_shows_the_breaker_when_there_is_one = function()
    local breaker = ctx.module.breaker.new({ name = 'etcd' })
    local own = instance({ breaker = breaker, deadline = 12 })

    t.assert_equals(own:status().deadline, 12)
    t.assert_equals(own:status().breaker.name, 'etcd')
    t.assert_equals(own:status().breaker.state, 'closed')
end

g.test_breaker_of_the_instance_guards_every_call = function()
    local breaker = ctx.module.breaker.new({ name = 'etcd', min_calls = 1, threshold = 1 })
    local own = instance({ attempts = 1, breaker = breaker })
    local reached = 0

    for _ = 1, 3 do
        own:run(function()
            reached = reached + 1

            return nil, 'узел недоступен'
        end)
    end

    -- Первый вызов уронил цепь; второму и третьему до сервера уже не дойти.
    t.assert_equals(reached, 1)
    t.assert_equals(own:status().breaker.state, 'open')
end
