--- Бюджет повторов: сколько лишней работы клиент вправе создать.
---
--- Предел попыток в одном вызове не спасает от лавины. Три попытки вместо
--- одной — это утроенная нагрузка; если между клиентом и сервером есть
--- посредник, который тоже повторяет, множители перемножаются, и четыре
--- уровня по три попытки дают восемьдесят один запрос на один исходный.
--- Беда в том, что множитель включается именно тогда, когда сервер и так
--- не справляется: повторы бьют по упавшему сервису и не дают ему встать.
---
--- Бюджет — ведро жетонов. Каждый отказ забирает жетон, каждая удача
--- возвращает `ratio` жетона. Повторять разрешено, пока жетонов больше
--- половины ведра. Смысл в соотношении, а не в числе: при `ratio = 0.1`
--- повторы живут, пока отказывает меньше каждого десятого вызова,
--- и кончаются, когда сервис лежит по-настоящему. Здоровая система
--- жетоны не тратит, больная перестаёт добивать себя сама — без настройки,
--- без выключателя и без человека, который вспомнит про него в три часа
--- ночи.
---
--- Первую попытку бюджет не трогает никогда. Он ограничивает лишнюю
--- работу, а не работу вообще: клиент, которому бюджет запретил бы
--- обращаться к серверу, — это отказ в обслуживании, устроенный
--- собственной защитой.
---
--- Ведро живёт в экземпляре `tnt.retry` и делится по `scope`. Общее ведро
--- на весь процесс означало бы, что лежащий etcd отбирает повторы
--- у здорового соседа, — поэтому у каждого получателя своё.
---
--- Чем поступились: ведро не знает о соседних узлах и о времени. Оно
--- считает доли отказов с той минуты, как его завели, и вчерашняя авария
--- держит его полупустым ровно до тех пор, пока удачные вызовы не нальют
--- жетоны обратно. Это и есть нужное поведение, но оно значит, что ведро
--- нельзя читать как «состояние сервиса прямо сейчас» — для этого есть
--- размыкатель с его окном.
---
--- Негодная настройка ведра — бросок в `new`: это ошибка программиста,
--- и узнать о ней надо на строке, где ведро заводят. Повторы проверяют
--- настройки ведра раньше, при сборке экземпляра, и отказывают парой
--- (`complaint`): их ведро заводится по первому обращению, посреди
--- работы, и бросок оттуда пришёл бы слишком поздно.

--- Проверки по имени без броска: отсюда текст отказа о незнакомой настройке.
local explain = require('tnt.must').explain

local rule = require('tnt.retry.rule')

local Module = {}

---@class TntRetryBudget
---@field max number Размер ведра
---@field ratio number Сколько жетона возвращает удача
---@field tokens number Сколько жетонов осталось
local Budget = {}
Budget.__index = Budget

--- Размер ведра по умолчанию.
---
--- Сто: столько отказов подряд нужно, чтобы срезать повторы, и половина
--- ведра — полсотни — это запас на обычную рябь, а не на аварию.
Module.DEFAULT_TOKENS = 100

--- Сколько жетона возвращает удачный вызов.
---
--- Одна десятая: повторы кончаются там, где отказывает больше каждого
--- десятого вызова.
Module.DEFAULT_RATIO = 0.1

---@class TntRetryBudgetOptions
---@field tokens number|nil Размер ведра
---@field ratio number|nil Сколько жетона возвращает удача

--- Как ведро называется в отказе: так же, как настройка повторов,
--- в которой его настройки приходят чаще всего. Ключи ведра называются
--- от него — `budget.tokens`, — и по тексту видно, что чинить.
local NAME = 'budget'

--- Заголовок отказа о незнакомом ключе и о настройках не таблицей.
local TITLE = 'настройка ' .. NAME

--- Настройки ведра для `must.explain.options`: ключ знаком, а значение
--- проверяется здесь, своим текстом — тем же, каким говорят о своих
--- значениях повторы.
---@type table<string, string>
local KNOWN = { tokens = '?', ratio = '?' }

--- Проверяет размер ведра; nil — умолчание.
---
--- Бесконечное ведро не безгранично, а мертво: повтор разрешён, пока
--- жетонов больше половины, а половина бесконечности — та же
--- бесконечность, и повторов не стало бы вовсе. Без бюджета — это
--- `budget = false`, а не ведро без дна.
---@param tokens any
---@return string|nil
local function wrong_tokens(tokens)
    if tokens == nil or (type(tokens) == 'number' and tokens > 0 and tokens < math.huge) then
        return nil
    end

    return rule.refusal(NAME .. '.tokens', 'конечное число больше нуля', tokens)
end

--- Значение настройки либо умолчание, если настройки нет.
---
--- Сравнение, а не `or`: `box.NULL` истинен, и `or` отдал бы его
--- вместо умолчания.
---@param value any
---@param default number
---@return number
local function given_or(value, default)
    if value == nil then
        return default
    end

    return value
end

--- Проверяет, сколько жетона возвращает удача; nil — умолчание.
---@param ratio any
---@return string|nil
local function wrong_ratio(ratio)
    if ratio == nil then
        return nil
    end

    return rule.share(ratio, NAME .. '.ratio')
end

--- Что не так с настройками ведра; nil — всё в порядке.
---
--- Умолчание — только у ключа, которого нет; `box.NULL` — тоже «нет»,
--- как и в слиянии настроек повторов: так приходит `null` из YAML и JSON.
--- А `false` вместо числа — ошибка, и молча заменить её умолчанием
--- значило бы её спрятать.
---@param opts any
---@return string|nil
function Module.complaint(opts)
    local given = opts or {}

    return explain.options(given, TITLE, KNOWN) or wrong_tokens(given.tokens) or wrong_ratio(given.ratio)
end

--- Заводит полное ведро.
---
--- Негодная настройка — бросок с местом того, кто заводит ведро.
---@param opts TntRetryBudgetOptions|nil
---@return TntRetryBudget
function Module.new(opts)
    local wrong = Module.complaint(opts)

    if wrong ~= nil then
        error(wrong, 2)
    end

    local given = opts or {}
    local max = given_or(given.tokens, Module.DEFAULT_TOKENS)

    return setmetatable({
        max = max,
        ratio = given_or(given.ratio, Module.DEFAULT_RATIO),
        tokens = max,
    }, Budget)
end

--- Разрешён ли ещё один повтор.
---@return boolean
function Budget:allow()
    return self.tokens > self.max / 2
end

--- Записывает исход попытки.
---@param ok boolean Удалась ли попытка
function Budget:record(ok)
    if ok then
        self.tokens = math.min(self.max, self.tokens + self.ratio)

        return
    end

    self.tokens = math.max(0, self.tokens - 1)
end

--- Наполняет ведро заново.
function Budget:reset()
    self.tokens = self.max
end

--- Что в ведре сейчас.
---@return { tokens: number, max: number, ratio: number, allowed: boolean }
function Budget:status()
    return {
        tokens = self.tokens,
        max = self.max,
        ratio = self.ratio,
        allowed = self:allow(),
    }
end

return Module
