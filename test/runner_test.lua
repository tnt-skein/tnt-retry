--- Проверки цикла повторов: попытка, приговор, пауза, остановка.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g, ctx = helper.group('tnt.retry.runner', 'tnt.retry.runner')

--- Настройки поверх умолчаний; отказ здесь — ошибка самой проверки.
---@param overrides table|nil
---@return table
local function settings_of(overrides)
    local options = helper.module('tnt.retry.options')
    local settings, err = options.resolve(options.defaults(), overrides)

    return (assert(settings, tostring(err)))
end

--- Гоняет действие через цикл повторов.
---@param action fun(context: table): any, any
---@param overrides table|nil
---@param bucket table|nil
---@return any value
---@return any err
local function run(action, overrides, bucket)
    return ctx.module.run(action, settings_of(overrides), bucket)
end

--- Размыкатель, который уже разомкнут.
---@return TntRetryBreaker
local function tripped()
    local breaker = helper.module('tnt.retry.breaker').new({
        name = 'etcd',
        min_calls = 1,
        threshold = 1,
        window = 2,
    })

    breaker:record(false, 'сеть пропала')

    return breaker
end

g.test_action_that_works_at_once_is_not_repeated = function()
    local on_attempt, seen = helper.recorder()

    local value, err = run(function()
        return 'готово', 'мелочь'
    end, { on_attempt = on_attempt })

    t.assert_equals(value, 'готово')
    t.assert_equals(err, 'мелочь')
    t.assert_equals(ctx.clock.slept, {})
    t.assert_equals(#seen, 1)
    t.assert_equals(helper.at(seen, 1).ok, true)
    t.assert_equals(helper.at(seen, 1).attempt, 1)
end

g.test_action_is_repeated_until_it_works = function()
    local action, tries = helper.flaky(2, 'сервер молчит')

    local value, err = run(action)

    t.assert_equals(value, 'готово')
    t.assert_equals(err, nil)
    t.assert_equals(#tries, 3)
    t.assert_equals(ctx.clock.slept, { 0.1, 0.2 })
end

g.test_thrown_refusal_is_repeated_like_any_other = function()
    local tries = 0

    local value = run(function()
        tries = tries + 1

        if tries < 3 then
            error('сеть пропала')
        end

        return 'готово'
    end)

    t.assert_equals(value, 'готово')
    t.assert_equals(tries, 3)
end

g.test_permanent_refusal_is_never_repeated = function()
    local on_attempt, seen = helper.recorder()
    local action, tries = helper.flaky(math.huge, 'неверный пароль')

    local value, err = run(action, { on_attempt = on_attempt })

    t.assert_equals(value, nil)
    t.assert_equals(err, 'неверный пароль')
    t.assert_equals(#tries, 1)
    t.assert_equals(ctx.clock.slept, {})
    t.assert_equals(helper.at(seen, 1).reason, ctx.module.PERMANENT)
end

g.test_attempts_run_out_and_the_last_refusal_is_what_the_caller_gets = function()
    local on_attempt, seen = helper.recorder()
    local number = 0

    local value, err = run(function()
        number = number + 1

        return nil, ('отказ №%d'):format(number)
    end, { on_attempt = on_attempt })

    t.assert_equals(value, nil)
    t.assert_equals(err, 'отказ №3')
    t.assert_equals(#seen, 3)
    t.assert_equals(helper.at(seen, 3).reason, ctx.module.ATTEMPTS)
    t.assert_equals(helper.at(seen, 3).ok, false)
    t.assert_equals(helper.at(seen, 1).delay, 0.1)
    t.assert_equals(helper.at(seen, 2).delay, 0.2)
    t.assert_equals(helper.at(seen, 3).delay, nil)
end

g.test_number_past_the_limit_reads_as_attempts_run_out = function()
    -- Цикл номеру перескочить не даёт, но `next_delay` открыта наружу,
    -- и «попыток сделано больше, чем разрешено» обязано читаться как
    -- «повторов больше нет», а не как «предел ещё не достигнут».
    local delay, reason = ctx.module.next_delay(5, settings_of({ attempts = 3 }), nil, 'сервер молчит', 0)

    t.assert_equals(delay, nil)
    t.assert_equals(reason, ctx.module.ATTEMPTS)
end

g.test_pause_landing_exactly_on_the_deadline_is_not_taken = function()
    local on_attempt, seen = helper.recorder()
    local action, tries = helper.flaky(math.huge, 'сервер молчит')

    -- Первая пауза ровно в срок: ждать её целиком значит начать попытку
    -- в тот миг, когда ждать уже нельзя.
    run(action, { attempts = 5, base = 0.5, deadline = 0.5, jitter = 0, on_attempt = on_attempt })

    t.assert_equals(#tries, 1)
    t.assert_equals(ctx.clock.slept, {})
    t.assert_equals(helper.at(seen, 1).reason, ctx.module.DEADLINE)
    t.assert_equals(helper.at(seen, 1).ok, false)
end

g.test_deadline_stops_before_a_pause_that_would_outlast_it = function()
    local on_attempt, seen = helper.recorder()
    local action, tries = helper.flaky(math.huge, 'сервер молчит')

    local _, err = run(action, {
        attempts = 10,
        deadline = 0.25,
        jitter = 0,
        on_attempt = on_attempt,
    })

    -- Десять попыток уместились бы в 25 секунд; срок отпустил две.
    t.assert_equals(#tries, 2)
    t.assert_equals(err, 'сервер молчит')
    t.assert_equals(ctx.clock.slept, { 0.1 })
    t.assert_equals(helper.at(seen, 2).reason, ctx.module.DEADLINE)
end

g.test_endless_repeats_end_with_the_deadline_and_not_before = function()
    local action, tries = helper.flaky(math.huge, 'сервер молчит')

    run(action, { attempts = math.huge, deadline = 1, jitter = 0 })

    t.assert_equals(#tries, 4)
    t.assert_equals(ctx.clock.slept, { 0.1, 0.2, 0.4 })
end

g.test_action_learns_which_attempt_it_is_and_how_much_time_is_left = function()
    local action, tries = helper.flaky(math.huge, 'сервер молчит')

    run(action, { attempts = 3, deadline = 10, jitter = 0 })

    t.assert_equals(helper.at(tries, 1).attempt, 1)
    t.assert_equals(helper.at(tries, 1).elapsed, 0)
    t.assert_equals(helper.at(tries, 1).left, 10)
    t.assert_equals(helper.at(tries, 2).attempt, 2)
    t.assert_almost_equals(helper.at(tries, 2).left, 9.9, 1e-12)
    t.assert_almost_equals(helper.at(tries, 3).elapsed, 0.3, 1e-12)
end

g.test_without_a_deadline_the_action_is_told_there_is_none = function()
    local action, tries = helper.flaky(math.huge, 'сервер молчит')

    run(action)

    t.assert_equals(helper.at(tries, 1).left, nil)
    t.assert_equals(helper.at(tries, 1).remaining(), nil)
end

g.test_time_left_is_counted_for_a_wait_from_the_loop_stamp = function()
    -- Отметка цикла событий отстаёт на три секунды работы без уступки,
    -- а таймаут действия ожидание отсчитает от неё. Чтобы кончиться в срок
    -- вызова, таймауту нужны все тринадцать секунд; по настоящим часам
    -- он кончился бы на три раньше срока.
    ctx.clock.lag = 3

    ---@type any
    local seen

    run(function(context)
        seen = context

        return 'готово'
    end, { deadline = 10 })

    t.assert_equals(seen.left, 13)
    t.assert_equals(seen.elapsed, 0, 'прошедшее время — по настоящим часам')
end

g.test_time_left_is_asked_anew_before_every_wait = function()
    -- Действие ждёт дважды: соединение, потом ответ. Снимок начала
    -- попытки, отданный второму ожиданию, продлил бы её за срок вызова
    -- на всё время первого.
    local asked = {}

    run(function(context)
        table.insert(asked, context.remaining())
        ctx.clock.advance(4)
        table.insert(asked, context.remaining())

        return 'готово'
    end, { deadline = 10 })

    t.assert_equals(asked, { 10, 6 })
end

g.test_pause_is_counted_from_the_loop_stamp = function()
    -- Попытка кончилась работой без уступки, и отметка цикла отстала
    -- на полсекунды. Пауза отсчитывается от неё, и без поправки вышла бы
    -- на полсекунды короче названной.
    local action = helper.flaky(1, 'сервер молчит')

    ctx.clock.lag = 0.5

    run(action, { attempts = 2, jitter = 0 })

    t.assert_equals(ctx.clock.slept, { 0.6 })
end

g.test_budget_cuts_the_repeats_when_the_service_is_down = function()
    local on_attempt, seen = helper.recorder()
    local bucket = helper.module('tnt.retry.budget').new({ tokens = 4 })
    local action, tries = helper.flaky(math.huge, 'сервер молчит')

    local _, err = run(action, { attempts = 10, on_attempt = on_attempt }, bucket)

    -- Ведро на четыре жетона: половина уходит за два отказа, и третьей
    -- попытки не будет, сколько бы ни разрешал `attempts`.
    t.assert_equals(#tries, 2)
    t.assert_equals(err, 'сервер молчит')
    t.assert_equals(bucket.tokens, 2)
    t.assert_equals(helper.at(seen, 2).reason, ctx.module.BUDGET)
end

g.test_successful_call_gives_a_share_of_a_token_back = function()
    local bucket = helper.module('tnt.retry.budget').new({ tokens = 4, ratio = 0.5 })

    run(helper.flaky(1, 'сервер молчит'), nil, bucket)

    t.assert_equals(bucket.tokens, 3.5)
end

g.test_pause_obeys_the_server_that_asked_to_wait = function()
    local asked = { status = 503, retry_after = 2 }
    local action = helper.flaky(1, asked)

    run(action, { jitter = 0 })

    -- Расчётная пауза была бы 0.1 секунды, но сервер один знает, когда
    -- у него снова будет место.
    t.assert_equals(ctx.clock.slept, { 2 })
end

g.test_request_of_the_server_never_shortens_the_computed_pause = function()
    local asked = { status = 503, retry_after = 0 }

    run(helper.flaky(1, asked), { base = 1, jitter = 0 })

    t.assert_equals(ctx.clock.slept, { 1 })
end

g.test_request_exactly_at_the_cap_is_still_honoured = function()
    -- Граница считается занятой в пользу повтора: потолок — это то,
    -- сколько ждать можно, а не то, после чего уже нельзя.
    run(helper.flaky(1, { status = 503, retry_after = 5 }), { max = 5 })

    t.assert_equals(ctx.clock.slept, { 5 })
end

g.test_reasons_are_named_the_same_way_for_everyone_who_reads_them = function()
    -- Имена причин уходят в `on_attempt`, в журнал и в чужие метрики:
    -- переименовать их молча — сломать чужие панели.
    t.assert_equals(ctx.module.PERMANENT, 'permanent')
    t.assert_equals(ctx.module.ATTEMPTS, 'attempts')
    t.assert_equals(ctx.module.DEADLINE, 'deadline')
    t.assert_equals(ctx.module.BUDGET, 'budget')
    t.assert_equals(ctx.module.ASKED, 'asked')
    t.assert_equals(ctx.module.BREAKER, 'breaker')
end

g.test_repeat_is_abandoned_when_the_server_asks_for_longer_than_the_cap = function()
    local on_attempt, seen = helper.recorder()
    local asked = { status = 503, retry_after = 30 }
    local action, tries = helper.flaky(math.huge, asked)

    local _, err = run(action, { max = 5, on_attempt = on_attempt })

    t.assert_equals(#tries, 1)
    t.assert_equals(ctx.clock.slept, {})
    t.assert_is(err, asked)
    t.assert_equals(helper.at(seen, 1).reason, ctx.module.ASKED)
end

g.test_open_breaker_never_lets_the_action_run = function()
    local on_attempt, seen = helper.recorder()
    local action, tries = helper.flaky(math.huge, 'сервер молчит')

    local value, err = run(action, { breaker = tripped(), on_attempt = on_attempt })

    t.assert_equals(#tries, 0)
    t.assert_equals(value, nil)
    t.assert_str_contains(err, 'размыкатель разомкнут: etcd не отвечает')
    t.assert_equals(helper.at(seen, 1).reason, ctx.module.BREAKER)
    t.assert_equals(helper.at(seen, 1).ok, false)
    t.assert_equals(helper.at(seen, 1).elapsed, 0)
end

g.test_breaker_that_opens_mid_call_gives_back_the_refusal_of_the_server = function()
    local breaker = helper.module('tnt.retry.breaker').new({
        name = 'etcd',
        min_calls = 1,
        threshold = 1,
        window = 2,
    })
    local action, tries = helper.flaky(math.huge, 'узел недоступен')

    local _, err = run(action, { attempts = 5, breaker = breaker })

    -- Размыкатель не пустил вторую попытку, но вызывающему важнее то,
    -- чем отказал сервер, а не то, что мы перестали его спрашивать.
    t.assert_equals(#tries, 1)
    t.assert_equals(err, 'узел недоступен')
    t.assert_equals(breaker:state(), 'open')
end

g.test_breaker_counts_successes_of_the_repeated_call = function()
    local breaker = helper.module('tnt.retry.breaker').new({ name = 'etcd', window = 4, min_calls = 4 })

    run(helper.flaky(1, 'сервер молчит'), { breaker = breaker })

    t.assert_equals(breaker:status().calls, 2)
    t.assert_equals(breaker:status().failures, 1)
end

g.test_own_notion_of_what_is_worth_repeating_wins_over_the_default = function()
    local action, tries = helper.flaky(math.huge, 'сервер молчит')

    run(action, {
        retriable = function(err)
            return err == 'ещё разок'
        end,
    })

    t.assert_equals(#tries, 1)
end

g.test_judge_that_throws_stops_the_repeats_instead_of_falling = function()
    local on_attempt, seen = helper.recorder()
    local action, tries = helper.flaky(math.huge, 'сервер молчит')

    local _, err = run(action, {
        on_attempt = on_attempt,
        retriable = function()
            error('судья сломался')
        end,
    })

    t.assert_equals(#tries, 1)
    t.assert_equals(err, 'сервер молчит')
    t.assert_equals(helper.at(seen, 1).reason, ctx.module.PERMANENT)
    t.assert_equals(ctx.logged('retriable бросил'), true)
end

g.test_listener_that_throws_does_not_break_the_repeats = function()
    local action, tries = helper.flaky(1, 'сервер молчит')

    local value = run(action, {
        on_attempt = function()
            error('слушатель сломался')
        end,
    })

    t.assert_equals(value, 'готово')
    t.assert_equals(#tries, 2)
    t.assert_equals(ctx.logged('on_attempt бросил и был пропущен'), true)
end

g.test_listener_hears_the_refusal_the_pause_and_the_time_spent = function()
    local on_attempt, seen = helper.recorder()

    run(helper.flaky(1, 'сервер молчит'), { jitter = 0, on_attempt = on_attempt })

    t.assert_equals(helper.at(seen, 1), {
        attempt = 1,
        ok = false,
        err = 'сервер молчит',
        elapsed = 0,
        delay = 0.1,
    })
    local second = helper.at(seen, 2)

    t.assert_equals(second.attempt, 2)
    t.assert_equals(second.ok, true)
    t.assert_almost_equals(second.elapsed, 0.1, 1e-9)
end

g.test_silent_refusal_reaches_the_caller_with_a_reason = function()
    local _, err = run(function()
        return nil
    end, { attempts = 1 })

    t.assert_equals(err, helper.module('tnt.retry.attempt').NO_REASON)
end
