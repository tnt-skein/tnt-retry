--- Повторы неудавшихся действий с отступом.
---
--- Сеть отказывает, и отказывает она чаще всего ненадолго: узел
--- перезапускается, лидер меняется, сервер на секунду захлебнулся.
--- Каждый сетевой клиент пишет вокруг этого один и тот же цикл — попытка,
--- пауза, ещё попытка, — и каждый пишет его чуть иначе: один забывает
--- разброс и добивает вставший сервер, другой повторяет «неверный
--- пароль», третий делает десять попыток по пять секунд там, где
--- вызывающий готов ждать десять. Цикл здесь один на всех.
---
--- Что пакет умеет и чем это отличается от `while` с `fiber.sleep`:
---
---   * отступ растёт степенью и размазан случаем — тысяча клиентов
---     не повторяет в одну секунду;
---   * `retriable` решает, что вообще имеет смысл повторять;
---   * `deadline` держит общий предел времени, а не только число попыток;
---   * бюджет повторов не даёт клиенту добивать лежащий сервис;
---   * размыкатель (`retry.breaker`) перестаёт звонить туда, где не берут
---     трубку;
---   * часы и пауза берутся через внешнюю зависимость — проверка минутного ожидания
---     не занимает минуту.
---
--- Пользоваться так:
---
---     local retry = require('tnt.retry')
---
---     -- Разовый вызов: три попытки, полный разброс, потолок паузы 5 с.
---     local body, err = retry.run(function()
---         return http.get('http://etcd:2379/v3/kv/range')
---     end)
---
---     -- Настроенная политика: настройки пишутся один раз, а не в каждом вызове.
---     local call = retry.policy({
---         attempts = 6,
---         deadline = 10,
---         scope = 'etcd',
---         breaker = retry.breaker.new({ name = 'etcd' }),
---     })
---
---     local value, failure = call(function(context)
---         return http.get(url, { timeout = context.left })
---     end)
---
--- Отказ возвращается парой `nil, err` — последней причиной, а не
--- выдуманной сводкой: вызывающему нужно знать, чем именно кончилось.
--- Почему повторы кончились, рассказывает `on_attempt` и журнал.
---
--- Чем поступились. Пакет не знает, безопасно ли повторять само действие.
--- «Отказ временный» не значит «повторять можно»: перевод денег,
--- оборвавшийся после того, как сервер его принял, выглядит временным
--- отказом и повторяется вторым переводом. Неидемпотентное действие
--- повторяют только под ключом `tnt.once`.

local attempt = require('tnt.retry.attempt')
local backoff = require('tnt.retry.backoff')
local breaker = require('tnt.retry.breaker')
local budget = require('tnt.retry.budget')
local classify = require('tnt.retry.classify')
local options = require('tnt.retry.options')
local runner = require('tnt.retry.runner')

local Module = {}

--- Части: доступны тем, кто собирает своё поведение.
Module.attempt = attempt
Module.backoff = backoff
Module.breaker = breaker
Module.budget = budget
Module.classify = classify
Module.options = options
Module.runner = runner

---@class TntRetry
---@field settings table Проверенные настройки экземпляра
---@field budget TntRetryBudgetOptions|false|nil Настройки вёдер бюджета
---@field buckets table<string, TntRetryBudget> Вёдра по именам получателей
local Retry = {}
Retry.__index = Retry

--- Настройки экземпляра, принятые последним `configure`.
---@type table
local configured

--- Общий экземпляр на процесс. Ленив нарочно: загрузка модуля не должна
--- заводить ни вёдер, ни размыкателей — их заводит первое обращение.
---@type TntRetry|nil
local shared

--- Собирает экземпляр из уже проверенных настроек.
---@param settings table
---@return TntRetry
local function build(settings)
    return setmetatable({
        settings = settings,
        budget = settings.budget,
        buckets = {},
    }, Retry)
end

--- Ведро бюджета названного получателя.
---
--- Вёдра заводятся по требованию: клиент, который ходит к трём службам,
--- не должен объявлять их заранее, а клиент, который ходит к одной,
--- не должен платить за чужие.
---@param scope string
---@return TntRetryBudget|nil
function Retry:bucket(scope)
    -- `false` — единственный способ сказать «без ведра»: `nil` значит
    -- «ведро по умолчанию», и путать их нельзя.
    if self.budget == false then
        return nil
    end

    local bucket = self.buckets[scope]

    if bucket == nil then
        bucket = budget.new(self.budget)
        self.buckets[scope] = bucket
    end

    return bucket
end

--- Выполняет действие по готовым настройкам.
---@param action fun(context: table): any, any
---@param settings table
---@return any value
---@return any err
function Retry:perform(action, settings)
    if type(action) ~= 'function' then
        return nil,
            ('повторять нечего: действие должно быть функцией, а пришло: %s'):format(
                type(action)
            )
    end

    return runner.run(action, settings, self:bucket(settings.scope))
end

--- Выполняет действие, повторяя его, пока это имеет смысл.
---@param action fun(context: table): any, any Что делать; получает номер попытки и остаток срока
---@param opts TntRetryOptions|nil Настройки этого вызова поверх настроек экземпляра
---@return any value Что вернуло удачное действие; nil, если не вышло
---@return any err Причина последнего отказа
function Retry:run(action, opts)
    local settings, err = options.resolve(self.settings, opts)

    if settings == nil then
        return nil, err
    end

    return self:perform(action, settings)
end

--- Настроенная функция повтора.
---
--- Настройки проверяются здесь и один раз: политика, собранная при
--- старте, либо годится, либо отказывает сразу — а не посреди аварии,
--- ради которой её и заводили.
---@param opts TntRetryOptions|nil
---@return (fun(action: fun(context: table): any, any, extra: TntRetryOptions|nil): any, any)|nil
---@return string|nil err
function Retry:policy(opts)
    local settings, err = options.resolve(self.settings, opts)

    if settings == nil then
        return nil, err
    end

    return function(action, extra)
        if extra == nil then
            return self:perform(action, settings)
        end

        local merged, wrong = options.resolve(settings, extra)

        if merged == nil then
            return nil, wrong
        end

        return self:perform(action, merged)
    end
end

--- Наполняет вёдра бюджета заново.
---
--- Нужно после того, как беду починили руками: ведро наливается удачными
--- вызовами, а их неоткуда взять, пока повторы срезаны.
function Retry:reset()
    for _, bucket in pairs(self.buckets) do
        bucket:reset()
    end
end

--- Что настроено и что с вёдрами сейчас.
---
--- Паролей и ключей здесь нет и не бывает: повторы их не видят. Зато
--- видно `worst_case` — сколько вызов может простоять в паузах; это тот
--- самый вопрос, который иначе считают в уме и ошибаются.
---@return table
function Retry:status()
    local buckets = {}

    for scope, bucket in pairs(self.buckets) do
        buckets[scope] = bucket:status()
    end

    return {
        attempts = self.settings.attempts,
        base = self.settings.base,
        factor = self.settings.factor,
        jitter = self.settings.jitter,
        max = self.settings.max,
        deadline = self.settings.deadline,
        scope = self.settings.scope,
        worst_case = options.worst_case(self.settings),
        budget = self.budget ~= false and buckets or false,
        breaker = self.settings.breaker ~= nil and self.settings.breaker:status() or nil,
    }
end

--- Заводит отдельный экземпляр: свои настройки, свои вёдра.
---@param opts TntRetryOptions|nil
---@return TntRetry|nil
---@return string|nil err
function Module.new(opts)
    local settings, err = options.resolve(options.defaults(), opts, true)

    if settings == nil then
        return nil, err
    end

    return build(settings)
end

--- Настраивает общий экземпляр.
---
--- Настройки проверяются здесь, а собранный по ним экземпляр забывается:
--- следующее обращение соберёт новый. Иначе `configure` посреди работы
--- оставил бы старые вёдра с новыми настройками.
---@param opts TntRetryOptions|nil
---@return boolean ok
---@return string|nil err
function Module.configure(opts)
    local settings, err = options.resolve(options.defaults(), opts, true)

    if settings == nil then
        return false, err
    end

    configured = settings
    shared = nil

    return true
end

--- Общий экземпляр на процесс.
---@return TntRetry
function Module.default()
    if shared == nil then
        shared = build(configured)
    end

    return shared
end

--- Выполняет действие через общий экземпляр.
---@param action fun(context: table): any, any
---@param opts TntRetryOptions|nil
---@return any value
---@return any err
function Module.run(action, opts)
    return Module.default():run(action, opts)
end

--- Настроенная функция повтора через общий экземпляр.
---@param opts TntRetryOptions|nil
---@return (fun(action: fun(context: table): any, any, extra: TntRetryOptions|nil): any, any)|nil
---@return string|nil err
function Module.policy(opts)
    return Module.default():policy(opts)
end

--- Наполняет вёдра общего экземпляра заново.
function Module.reset()
    Module.default():reset()
end

--- Что настроено у общего экземпляра.
---@return table
function Module.status()
    return Module.default():status()
end

Module.configure(nil)

return Module
