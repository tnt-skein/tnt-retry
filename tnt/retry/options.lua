--- Настройки повторов: умолчания, слияние и проверка.
---
--- Проверяется всё и сразу — при заведении экземпляра, при сборке политики
--- и перед первой попыткой. Настройка повторов задаётся однажды и живёт
--- годами, а её ошибка проявляется только в аварии: `factor = 0.5` вместо
--- `2` уменьшает паузу с каждой попыткой и превращает защиту в ускоритель
--- лавины. Обнаружить такое в тот день, когда оно сработает, — значит
--- не обнаружить вовсе.
---
--- Незнакомое имя настройки — ошибка, а не безобидная добавка.
--- `attemps = 10` не опечатка в комментарии: настройка не применится,
--- повторов будет три вместо десяти, и не скажет об этом никто.
---
--- Отказ здесь — пара `nil, err`, и о незнакомой настройке тоже: так
--- отвечают все отказы настроек повторов, и `factor = 0.5` — ошибка того
--- же рода, что и `attemps`. Бросай один из них, вызывающему пришлось бы
--- ловить отказ настроек двумя способами. Общий с другими пакетами у этого
--- отказа только текст — «ключа «x» нет, есть …».
---
--- Каждый отказ начинается словами «настройки повторов»: пакет называет
--- себя сам, и текст один, кто бы ни передал настройки — прикладной код,
--- клиент HTTP или драйвер. Своя приставка у того, кто передаёт отказ
--- дальше, не нужна: вызывающий прочёл бы её дважды подряд.
---
--- Проверяются и вложенные настройки ведра (`budget`): незнакомый ключ
--- в них молча оставил бы умолчание — `{ token = 4 }` дал бы ведро на сто
--- жетонов, — а строка вместо числа сломала бы первый же повтор, посреди
--- работы.

local backoff = require('tnt.retry.backoff')
local budget = require('tnt.retry.budget')
local classify = require('tnt.retry.classify')
local rule = require('tnt.retry.rule')

--- Проверки по имени без броска: отсюда текст отказа о незнакомой настройке.
local explain = require('tnt.must').explain

local Module = {}

--- Сколько попыток делать всего, считая первую.
---
--- Три: первая, и ещё две на случай, что беда была мгновенной. Больше
--- стоит ставить только вместе со сроком — иначе десять попыток по пять
--- секунд превращаются в минуту ожидания там, где вызывающий готов ждать
--- десять.
Module.DEFAULT_ATTEMPTS = 3

--- Первая пауза.
---
--- Десятая доля секунды: меньше — и повтор приходит раньше, чем сервер
--- успел выдохнуть; больше — и вызов, который спасла бы мгновенная вторая
--- попытка, платит за это заметным для человека временем.
Module.DEFAULT_BASE = 0.1

--- Во сколько раз растёт пауза.
Module.DEFAULT_FACTOR = 2

--- Доля паузы, отданная случаю.
---
--- Единица — полный разброс: пауза равномерна от нуля до расчётной. Так
--- меньше всего лишних обращений и быстрее всего общий успех, когда
--- клиентов много. Тому, кому нужна гарантированная нижняя граница паузы,
--- нужен 0.5 — «равный разброс».
Module.DEFAULT_JITTER = 1

--- Потолок паузы.
---
--- Пять секунд: дольше ждать внутри одного вызова бессмысленно — беда,
--- не прошедшая за пять секунд, не пройдёт и за тридцать, а вызывающий
--- всё это время держит файбер и, чаще всего, человека.
Module.DEFAULT_MAX = 5

--- Имя ведра бюджета, если вызывающий не назвал своё.
Module.DEFAULT_SCOPE = 'default'

--- Как настройки называются в отказе.
local TITLE = 'настройки повторов'

--- Настройки, которые можно задать и экземпляру, и отдельному вызову.
---
--- Описание для `must.explain.options`: ключ знаком, а значение — любое
--- (`'?'`). Значения проверяет `check` своим текстом, и не здесь, а после
--- слияния: попытки пойдут с тем, что вышло из слияния, а не с тем, что
--- пришло.
---@type table<string, string>
local CALL_KNOWN = {
    attempts = '?',
    base = '?',
    factor = '?',
    jitter = '?',
    max = '?',
    deadline = '?',
    retriable = '?',
    on_attempt = '?',
    scope = '?',
    breaker = '?',
}

--- Настройки экземпляра: те же, что у вызова, и ведро бюджета сверх них.
---
--- Ведро общее для всех вызовов экземпляра: разрешать отдельному вызову
--- своё ведро значит разрешить обойти защиту, а защита, которую обходят
--- по вкусу, никого не защищает.
---
--- Набор собирается один раз: пересобирать его на каждом слиянии значило
--- бы мусорить таблицей на каждый вызов `run`.
---@type table<string, string>
local INSTANCE_ALLOWED = { budget = '?' }

for name, entry in pairs(CALL_KNOWN) do
    INSTANCE_ALLOWED[name] = entry
end

--- Числовые настройки и их нижние границы.
---
--- `factor` не меньше единицы: множитель меньше единицы сокращает паузу
--- с каждой попыткой — это не отступ, а разгон.
local NUMBERS = {
    { name = 'base', least = 0 },
    { name = 'factor', least = 1 },
    { name = 'max', least = 0 },
}

---@class TntRetryOptions
---@field attempts number|nil Сколько попыток всего, считая первую
---@field base number|nil Первая пауза в секундах
---@field factor number|nil Во сколько раз растёт пауза
---@field jitter number|string|nil Доля случая от 0 до 1 либо 'decorrelated'
---@field max number|nil Потолок одной паузы в секундах
---@field deadline number|nil Общий предел времени на весь вызов, секунды
---@field retriable (fun(err: any): boolean)|nil Что повторять
---@field on_attempt (fun(info: table))|nil Что звать после каждой попытки
---@field scope string|nil Имя ведра бюджета
---@field breaker TntRetryBreaker|nil Размыкатель
---@field budget TntRetryBudgetOptions|false|nil Ведро бюджета; только экземпляру

--- Умолчания: свежая таблица на каждый вызов.
---@return table
function Module.defaults()
    return {
        attempts = Module.DEFAULT_ATTEMPTS,
        base = Module.DEFAULT_BASE,
        factor = Module.DEFAULT_FACTOR,
        jitter = Module.DEFAULT_JITTER,
        max = Module.DEFAULT_MAX,
        scope = Module.DEFAULT_SCOPE,
        retriable = classify.of,
    }
end

--- Число ли это и не меньше ли оно границы.
---@param value any
---@param name string
---@param least number
---@return string|nil Чего не хватает
local function wrong_number(value, name, least)
    -- `value ~= value` — это NaN: он не число ни в каком полезном смысле,
    -- а сравнения с ним всегда ложны, и пауза длиной NaN длится вечно.
    if type(value) ~= 'number' or value ~= value then
        return ('настройка %s должна быть числом, а пришло: %s'):format(
            name,
            tostring(value)
        )
    end

    if value < least then
        return ('настройка %s не может быть меньше %s'):format(name, tostring(least))
    end

    return nil
end

--- Проверяет число попыток.
---@param settings table
---@return string|nil
local function wrong_attempts(settings)
    local attempts = settings.attempts

    if attempts == math.huge then
        if settings.deadline == nil then
            -- Бесконечные повторы без срока — худший выбор из возможных:
            -- вызов не кончается никогда, файбер занят навсегда, а беда
            -- выглядит как «панель просто не отвечает».
            return 'бесконечные повторы без срока: задайте deadline или конечный attempts'
        end

        return nil
    end

    return rule.count(attempts, 'attempts')
end

--- Проверяет разброс.
---
--- Граница — сравнением «годится»: доля NaN прошла бы границу, записанную
--- отрицанием, и пауза вышла бы длиной NaN.
---@param jitter any
---@return string|nil
local function wrong_jitter(jitter)
    if jitter == backoff.DECORRELATED or (type(jitter) == 'number' and jitter >= 0 and jitter <= 1) then
        return nil
    end

    return rule.refusal('jitter', ("доля от 0 до 1 либо '%s'"):format(backoff.DECORRELATED), jitter)
end

--- Проверяет срок.
---@param deadline any
---@return string|nil
local function wrong_deadline(deadline)
    if deadline == nil then
        return nil
    end

    return rule.seconds(deadline, 'deadline')
end

--- Проверяет размыкатель: он нужен целиком, а не похожим на себя.
---@param given any
---@return string|nil
local function wrong_breaker(given)
    if given == nil then
        return nil
    end

    if type(given) ~= 'table' or type(given.allow) ~= 'function' then
        return 'настройка breaker — размыкатель из retry.breaker.new'
    end

    return nil
end

--- Проверяет ведро бюджета: и что это таблица, и что в ней.
---@param given any
---@return string|nil
local function wrong_budget(given)
    if given == nil or given == false then
        return nil
    end

    if type(given) ~= 'table' then
        return 'настройка budget — таблица настроек ведра либо false'
    end

    return budget.complaint(given)
end

--- Проверяет имя ведра.
---@param scope any
---@return string|nil
local function wrong_scope(scope)
    if type(scope) == 'string' then
        return nil
    end

    return ('настройка scope — имя ведра строкой, а пришло: %s'):format(
        tostring(scope)
    )
end

--- Что не так с собранными настройками; nil — всё в порядке.
---@param settings table
---@return string|nil
local function complaint(settings)
    for _, number in ipairs(NUMBERS) do
        local wrong_field = wrong_number(settings[number.name], number.name, number.least)

        if wrong_field ~= nil then
            return wrong_field
        end
    end

    local wrong = wrong_attempts(settings)
        or wrong_jitter(settings.jitter)
        or wrong_deadline(settings.deadline)
        or rule.callable(settings.retriable, 'retriable')
        or rule.callable(settings.on_attempt, 'on_attempt')
        or wrong_breaker(settings.breaker)
        or wrong_budget(settings.budget)
        or wrong_scope(settings.scope)

    if wrong ~= nil then
        return wrong
    end

    if settings.retriable == nil then
        return 'настройка retriable должна быть функцией'
    end

    if settings.max < settings.base then
        return 'настройка max меньше base: потолок ниже первой же паузы'
    end

    return nil
end

--- Проверяет собранные настройки.
---@param settings table
---@return table|nil settings Те же настройки, если с ними всё в порядке
---@return string|nil err
function Module.check(settings)
    local wrong = complaint(settings)

    if wrong ~= nil then
        return nil, ('%s: %s'):format(TITLE, wrong)
    end

    return settings
end

--- Накладывает заданное на уже принятое.
---@param base table Принятые настройки
---@param overrides table|nil Что меняем
---@param instance boolean|nil Настройки экземпляра, а не отдельного вызова
---@return table|nil settings
---@return string|nil err
function Module.merge(base, overrides, instance)
    overrides = overrides or {}

    local allowed = CALL_KNOWN

    if instance then
        allowed = INSTANCE_ALLOWED
    end

    local stray = explain.options(overrides, TITLE, allowed)

    if stray ~= nil then
        return nil, stray
    end

    local merged = {}

    for name in pairs(allowed) do
        local given = overrides[name]

        if given == nil then
            given = base[name]
        end

        merged[name] = given
    end

    return merged
end

--- Сливает и проверяет за один заход.
---@param base table
---@param overrides table|nil
---@param instance boolean|nil
---@return table|nil settings
---@return string|nil err
function Module.resolve(base, overrides, instance)
    local merged, err = Module.merge(base, overrides, instance)

    if merged == nil then
        return nil, err
    end

    return Module.check(merged)
end

--- Сколько вызов простоит в паузах в самом худшем случае.
---
--- Разброс паузу только укорачивает, поэтому это верхняя граница — и она
--- же ответ на вопрос «сколько это может занять», который иначе считают
--- в уме и ошибаются. Для стратегии `decorrelated` это оценка: она считает
--- паузу от прошлой, а не от номера попытки.
---@param settings table
---@return number Секунды
function Module.worst_case(settings)
    if settings.attempts == math.huge then
        return settings.deadline or math.huge
    end

    ---@type number
    local total = 0

    for number = 1, settings.attempts - 1 do
        total = total + backoff.raw(number, settings)
    end

    if settings.deadline ~= nil then
        return math.min(total, settings.deadline)
    end

    return total
end

return Module
