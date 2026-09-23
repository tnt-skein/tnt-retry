--- Сколько ждать перед следующей попыткой.
---
--- Отступ растёт степенью: `base`, `base * factor`, `base * factor^2`
--- и так до потолка `max`. Растёт он не из вежливости. Сервер падает
--- под нагрузкой, и повторы — это добавленная нагрузка ровно в тот миг,
--- когда её и так больше, чем он держит; редеющие попытки дают ему шанс
--- разгрестись.
---
--- Разброс (jitter) важнее самой степени. Тысяча клиентов, отказавших
--- в одну секунду, без разброса повторит в одну же — и вставший сервер
--- получит ту самую тысячу запросов одним ударом, ляжет снова, и всё
--- повторится через удвоенный промежуток. Разброс размазывает тысячу
--- по промежутку, и сервер видит поток, а не удар.
---
--- `jitter` — доля паузы, отданная случаю, от 0 до 1:
---
---     пауза = raw * (1 - jitter) + random() * raw * jitter
---
--- Одна формула вместо трёх нарочно: разброс — это не выбор из списка
--- названий, а ручка с непрерывной шкалой, и у её крайних положений
--- есть устоявшиеся имена.
---
---   * 0 — разброса нет вовсе, чистая степень;
---   * 0.5 — «равный разброс» (equal jitter): половина паузы
---     гарантирована, половина случайна, `temp/2 + random(0, temp/2)`;
---   * 1 — «полный разброс» (full jitter): `random(0, temp)`.
---
--- Отдельно стоит `jitter = 'decorrelated'`. Там пауза считается
--- не от номера попытки, а от прошлой паузы: `min(cap, random(base,
--- prev * 3))`. Она растёт быстрее полного разброса и не имеет
--- «ступеней», к которым клиенты могут сойтись, — но требует памяти
--- о прошлой паузе и потому не годится там, где попытки идут разными
--- вызовами. Когда много клиентов спорят за один сервер, полный разброс
--- даёт чуть меньше общей работы, раскоррелированный — чуть меньшее время
--- до успеха; равный проигрывает обоим, а отсутствие разброса — всем.
---
--- Случай берётся у ядра (`digest.urandom`), а не у `math.random`:
--- его Tarantool не сеет, и каждый процесс начинает с одной и той же
--- последовательности. Узлы, отказавшие в один миг, получили бы одни
--- и те же паузы — разброс, который ничего не разбрасывает. Сеять его
--- отсюда значило бы менять общий на процесс генератор под ногами у всех,
--- кто им пользуется.

local digest = require('digest')

local external = require('tnt.external')

local Module = {}

--- Имя стратегии, считающей паузу от прошлой паузы.
Module.DECORRELATED = 'decorrelated'

--- Во сколько раз раскоррелированный разброс поднимает верхнюю границу
--- над прошлой паузой.
---
--- Тройка: середина промежутка от `base` до трёх прошлых пауз — полторы
--- прошлых, и пауза в среднем растёт в полтора раза за попытку, а её
--- разброс остаётся шириной почти во весь промежуток.
local DECORRELATED_GROWTH = 3

--- Сколько байтов ядра уходит на одну случайную долю.
---
--- Четыре дают 2^32 ступеней: на паузе в пять секунд шаг — чуть больше
--- наносекунды, на часовой — меньше микросекунды, то есть мельче, чем
--- отмеряет сон. Больше байтов — лишнее чтение без разницы в паузе.
local RANDOM_BYTES = 4

---@class TntRetryBackoffSource
---@field random fun(): number Доля от 0 до 1, не включая 1
---@field urandom fun(count: integer): string Байты ядра

--- Внешние средства: случай и байты ядра, из которых он берётся.
---
--- `random` — доля от 0 до 1, и проверки подменяют её числом, чтобы
--- считать паузу арифметикой. `urandom` подменяют те, кто проверяет
--- саму долю: сколько байтов она просит и что из них складывает.
---@type fun(): TntRetryBackoffSource
local source

--- Случайная доля от 0 до 1, не включая 1, из байтов ядра.
---@return number
local function random()
    return Module.fraction(source().urandom(RANDOM_BYTES))
end

source = external.install(Module, { random = random, urandom = digest.urandom })

--- Доля от 0 до 1, не включая 1, из байтов: число, записанное ими
--- со старшего, делённое на число всех возможных записей той же длины.
---@param bytes string
---@return number
function Module.fraction(bytes)
    local number = 0

    for index = 1, #bytes do
        number = number * 256 + bytes:byte(index)
    end

    return number / 256 ^ #bytes
end

--- Отступ без разброса: степень, срезанная потолком.
---@param number integer Номер уже сделанной попытки, начиная с единицы
---@param opts { base: number, factor: number, max: number }
---@return number
function Module.raw(number, opts)
    local raw = opts.base * opts.factor ^ (number - 1)

    -- Степень растёт быстро и на паре тысяч попыток уходит
    -- в бесконечность, а `0 * inf` — это NaN: пауза, сравнения с которой
    -- всегда ложны, то есть пауза, которой нет. Ловится она сравнением
    -- с самой собой — единственным, что отличает NaN от числа.
    if raw ~= raw then
        return opts.max
    end

    return math.min(raw, opts.max)
end

--- Пауза, посчитанная от прошлой паузы.
---@param opts { base: number, max: number }
---@param previous number|nil Прошлая пауза; при первой попытке её нет
---@return number
local function decorrelated(opts, previous)
    local from = opts.base
    local to = (previous or opts.base) * DECORRELATED_GROWTH

    return math.min(from + source().random() * (to - from), opts.max)
end

--- Пауза перед следующей попыткой.
---@param number integer Номер уже сделанной попытки, начиная с единицы
---@param opts { base: number, factor: number, jitter: number|string, max: number }
---@param previous number|nil Прошлая пауза; нужна только стратегии decorrelated
---@return number
function Module.delay_for(number, opts, previous)
    if opts.jitter == Module.DECORRELATED then
        return decorrelated(opts, previous)
    end

    local raw = Module.raw(number, opts)
    local spread = raw * opts.jitter

    return raw - spread + source().random() * spread
end

return Module
