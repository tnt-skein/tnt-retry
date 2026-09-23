--- Цикл повторов: попытка, приговор, пауза, снова попытка.
---
--- Здесь собрано всё, что решает, будет ли ещё одна попытка. Причин
--- остановиться шесть, и каждая называется вслух — и в `on_attempt`,
--- и в журнале. Молчаливая остановка («просто не вышло») хуже любой
--- названной: по ней нельзя отличить сервер, который отказал навсегда,
--- от бюджета, который кончился на здоровом сервере.
---
--- Срок (`deadline`) меряется монотонными часами и считается от начала
--- вызова, а не от начала попытки. Он не обрывает уже идущую попытку —
--- оборвать чужой вызов на середине отсюда нельзя, у него свои сроки, —
--- а решает, есть ли смысл начинать следующую: если пауза перед ней уже
--- выходит за срок, повторов больше нет. Сколько срока осталось, действие
--- узнаёт из своего единственного аргумента — и вправе сложить это в свой
--- собственный таймаут.
---
--- Чужие функции — `retriable` и `on_attempt` — зовутся под pcall.
--- Брошенное ими не должно доходить до вызывающего: он просил повторить
--- действие, а не поручал пакету свою целость. Бросивший `retriable`
--- считается сказавшим «не повторять»: повторять, опираясь на сломанное
--- суждение, значит бить по серверу наугад.
---
--- Чем поступились: в `on_attempt` не передаётся значение, которое
--- вернула удачная попытка. Обработчик почти всегда пишет в журнал или
--- в метрики, а значение — это те самые данные, ради которых вызов
--- и делался; ронять их в журнал по умолчанию нельзя.

local attempt = require('tnt.retry.attempt')
local backoff = require('tnt.retry.backoff')
local classify = require('tnt.retry.classify')

local clock = require('tnt.clock')
local external = require('tnt.external')

local log = require('tnt.log').new('tnt.retry')

local Module = {}

--- Почему повторов больше не будет.
Module.PERMANENT = 'permanent' -- отказ не из тех, что лечит время
Module.ATTEMPTS = 'attempts' -- попытки кончились
Module.DEADLINE = 'deadline' -- срок не оставил места ещё одной попытке
Module.BUDGET = 'budget' -- бюджет повторов исчерпан
Module.ASKED = 'asked' -- сервер попросил ждать дольше, чем разрешает max
Module.BREAKER = 'breaker' -- размыкатель не пустил вызов

--- Внешние средства: часы и пауза.
---
--- Часы монотонные: срок меряется длительностью, а перевод стенных часов
--- назад посреди ожидания продлил бы его на разницу. Монотонных двое,
--- по правилу `tnt-clock`. Начало вызова, прошедшее время и решение,
--- осталось ли место ещё одной попытке, — это миг и длительности, они
--- на настоящих часах (`now`). То, что уходит в ожидание, — остаток срока
--- для таймаута действия и пауза перед повтором, — считается от времени
--- планировщика (`scheduler_now`): ожидание отсчитывает его от отметки цикла
--- событий, а та стоит, пока идёт работа без уступки.
local source = external.install(Module, {
    now = clock.monotonic,
    scheduler_now = clock.scheduler_now,
    sleep = clock.sleep,
})

--- Сообщает вызывающему об исходе попытки.
---@param on_attempt (fun(info: table))|nil
---@param info table
local function tell(on_attempt, info)
    if on_attempt == nil then
        return
    end

    local told, err = pcall(on_attempt, info)

    if not told then
        log.warn('on_attempt бросил и был пропущен', { err = tostring(err) })
    end
end

--- Стоит ли повторять этот отказ по мнению настроенного судьи.
---@param settings table
---@param err any
---@return boolean
local function retriable_of(settings, err)
    local judged, verdict = pcall(settings.retriable, err)

    if not judged then
        log.warn(
            'retriable бросил; отказ считается постоянным',
            { err = tostring(verdict) }
        )
    end

    -- У бросившего судьи `verdict` — текст броска, то есть истина, и решает
    -- `judged`. Одно выражение, а не ранний `return false`: зовущий читает
    -- ответ только как истину или ложь, и у отдельной ветки мутант `nil`
    -- был бы неотличим.
    return judged and verdict and true or false
end

--- Пауза перед следующей попыткой либо причина обойтись без неё.
---@param number integer Номер сделанной попытки
---@param settings table Проверенные настройки
---@param previous number|nil Прошлая пауза; нужна стратегии decorrelated
---@param err any Чем кончилась попытка
---@param spent number Сколько времени ушло от начала вызова
---@param bucket TntRetryBudget|nil Ведро бюджета
---@return number|nil delay Пауза в секундах; nil — повторов больше нет
---@return string|nil reason Почему их нет
function Module.next_delay(number, settings, previous, err, spent, bucket)
    if not retriable_of(settings, err) then
        return nil, Module.PERMANENT
    end

    if number >= settings.attempts then
        return nil, Module.ATTEMPTS
    end

    if bucket ~= nil and not bucket:allow() then
        return nil, Module.BUDGET
    end

    local delay = backoff.delay_for(number, settings, previous)
    local asked = classify.delay_of(err)

    if asked ~= nil then
        -- Сервер назвал срок, и спорить с ним не о чем: он один знает,
        -- когда у него снова будет место. Но если названное больше
        -- потолка, повтора не будет вовсе — прийти раньше значит сделать
        -- ровно то, о чём просили не делать, а ждать дольше потолка
        -- вызывающий не подписывался.
        if asked > settings.max then
            return nil, Module.ASKED
        end

        delay = math.max(delay, asked)
    end

    if settings.deadline ~= nil and spent + delay >= settings.deadline then
        return nil, Module.DEADLINE
    end

    return delay
end

--- Заканчивает вызов отказом, назвав причину.
---@param settings table
---@param info table
---@return nil
---@return any err
local function give_up(settings, info)
    tell(settings.on_attempt, info)
    log.debug('повторов больше не будет', {
        attempt = info.attempt,
        reason = info.reason,
        elapsed = info.elapsed,
    })

    return nil, info.err
end

--- Что известно действию о его попытке.
---
--- Остаток срока отдаётся действию для таймаута, то есть для ожидания,
--- и считается от времени планировщика: ожидание отсчитает его от той же
--- отметки цикла событий и кончится ровно в срок вызова, даже если перед
--- ним шла работа без уступки. Остаток по настоящим часам кончился бы
--- раньше срока на всю такую работу.
---
--- `left` — снимок на начало попытки, и годится он одному ожиданию, начатому
--- сразу. Действие, которое ждёт не один раз (переходы по адресам, ответ
--- после соединения) или уступает управление до ожидания, спрашивает
--- `remaining()` перед каждым: снимок, отданный второму ожиданию, продлил бы
--- попытку за срок вызова на всё время первого.
---@param number integer
---@param spent number Сколько прошло от начала вызова по настоящим часам
---@param remaining fun(): number|nil
---@return table
local function context_of(number, spent, remaining)
    return { attempt = number, elapsed = spent, left = remaining(), remaining = remaining }
end

--- Выполняет действие, повторяя его, пока это имеет смысл.
---@param action fun(context: table): any, any
---@param settings table Уже проверенные настройки
---@param bucket TntRetryBudget|nil Ведро бюджета экземпляра
---@return any value Что вернуло удачное действие; nil, если не вышло
---@return any err Причина последнего отказа
function Module.run(action, settings, bucket)
    local tools = source()
    local started = tools.now()
    local breaker = settings.breaker
    local number = 0
    local delay
    local last_err

    --- Остаток срока вызова для ожидания, которое начинается прямо сейчас.
    ---@return number|nil
    local function remaining()
        if settings.deadline == nil then
            return nil
        end

        return settings.deadline - (tools.scheduler_now() - started)
    end

    while true do
        number = number + 1

        if breaker ~= nil then
            local allowed, refusal = breaker:allow()

            if not allowed then
                return give_up(settings, {
                    attempt = number,
                    ok = false,
                    -- На первой попытке отказал сам размыкатель, и его
                    -- слова — единственное, что случилось. Дальше важнее
                    -- то, чем отказал сервер: размыкатель лишь перестал
                    -- ждать от него другого ответа.
                    err = last_err or refusal,
                    elapsed = tools.now() - started,
                    reason = Module.BREAKER,
                })
            end
        end

        local before = tools.now() - started
        local ok, value, err = attempt.once(action, context_of(number, before, remaining))
        local spent = tools.now() - started

        if breaker ~= nil then
            breaker:record(ok, err)
        end

        if bucket ~= nil then
            bucket:record(ok)
        end

        if ok then
            tell(settings.on_attempt, { attempt = number, ok = true, elapsed = spent })

            return value, err
        end

        last_err = err

        local reason
        delay, reason = Module.next_delay(number, settings, delay, err, spent, bucket)

        if delay == nil then
            return give_up(settings, {
                attempt = number,
                ok = false,
                err = err,
                elapsed = spent,
                reason = reason,
            })
        end

        tell(settings.on_attempt, {
            attempt = number,
            ok = false,
            err = err,
            elapsed = spent,
            delay = delay,
        })
        log.debug('повтор после отказа', { attempt = number, delay = delay, err = tostring(err) })

        -- Пауза — от мига решения, а отмеряет её ожидание, то есть от отметки
        -- цикла событий. Отставание отметки прибавляется: попытка, кончившаяся
        -- работой без уступки, иначе укоротила бы паузу на её время, а паузу,
        -- названную сервером, укорачивать нельзя.
        tools.sleep(delay + (tools.now() - tools.scheduler_now()))
    end
end

return Module
