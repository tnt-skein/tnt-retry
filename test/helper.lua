--- Общие средства тестов пакета повторов.
---
--- Исходники читаются с диска, а не через `require`: у Tarantool свой
--- загрузчик `.rocks`, он идёт раньше `package.path` и подсунул бы
--- установленную копию пакета, если она есть. Проверки тогда шли бы
--- против вчерашнего кода, а покрытие считалось бы по нему. Зависимости
--- пакета — `tnt.must`, `tnt.clock`, `tnt.log`, `tnt.external` — берутся
--- из `.rocks` обычным `require`: проверяется этот пакет, а не они.
--- Ловушка журнала встаёт и на установленный `tnt.log` — тот же
--- экземпляр, которым пишут повторы и размыкатель.
---
--- Оснастка в `test/testing/` — загрузчик исходников, часы, которые
--- двигает проверка, и ловушка журнала — грузится так же и один раз
--- на процесс: второй экземпляр загрузчика не знал бы, что вытеснил
--- первый, и не вернул бы вытесненное на место.
---
--- Проверки берут всё через помощник, а не из оснастки напрямую: помощник —
--- единственное, чем файл проверок отличается от того же файла в наборе,
--- где пакет живёт рядом со своими зависимостями.

local fio = require('fio')
local t = require('luatest')

--- Модули оснастки в порядке зависимостей.
local TESTING = {
    { name = 'tnt.testing.sources', path = 'test/testing/sources.lua' },
    { name = 'tnt.testing.clock', path = 'test/testing/clock.lua' },
    { name = 'tnt.testing.journal', path = 'test/testing/journal.lua' },
}

for _, module in ipairs(TESTING) do
    if package.loaded[module.name] == nil then
        local chunk, failure = loadfile(fio.abspath(module.path))

        if chunk == nil then
            error(('оснастка %s не читается: %s'):format(module.name, tostring(failure)))
        end

        package.loaded[module.name] = chunk()
    end
end

--- Оснастка проверок под теми именами, что зовёт помощник.
local testing = {
    load_sources = package.loaded['tnt.testing.sources'].load,
    unload_sources = package.loaded['tnt.testing.sources'].unload,
    module = package.loaded['tnt.testing.sources'].module,
    clock = package.loaded['tnt.testing.clock'].new,
    capture_log = package.loaded['tnt.testing.journal'].capture,
}

local helper = {}

--- Модули пакета в порядке зависимостей.
helper.MODULES = {
    { name = 'tnt.retry.attempt', path = 'tnt/retry/attempt.lua' },
    { name = 'tnt.retry.backoff', path = 'tnt/retry/backoff.lua' },
    { name = 'tnt.retry.classify', path = 'tnt/retry/classify.lua' },
    { name = 'tnt.retry.rule', path = 'tnt/retry/rule.lua' },
    { name = 'tnt.retry.budget', path = 'tnt/retry/budget.lua' },
    { name = 'tnt.retry.breaker', path = 'tnt/retry/breaker.lua' },
    { name = 'tnt.retry.options', path = 'tnt/retry/options.lua' },
    { name = 'tnt.retry.runner', path = 'tnt/retry/runner.lua' },
    { name = 'tnt.retry', path = 'tnt/retry.lua' },
}

--- Уже загруженный модуль пакета: проверке цикла повторов нужны соседи.
helper.module = testing.module

--- Ставит случай, который всегда даёт одно и то же число.
---
--- Разброс по определению случаен, и проверять по нему точные паузы
--- нельзя: сегодня повезёт, завтра нет. Подменённый случай делает
--- расчёт паузы обычной арифметикой.
---@param value number
function helper.random(value)
    testing.module('tnt.retry.backoff')._set_source({
        random = function()
            return value
        end,
    })
end

--- Раздаёт подменённые средства всем, кто их берёт.
---
--- Часы — двойник из оснастки: время двигает сама пауза, а отметка цикла
--- событий отстаёт на `lag`, как после работы без уступки. Случай
--- по умолчанию — единица: при полном разбросе пауза тогда равна
--- расчётной, и проверка говорит о степени, а не о везении.
---@param clock TntTestingClock
function helper.arm(clock)
    testing.module('tnt.retry.breaker')._set_source({ now = clock.monotonic })
    testing.module('tnt.retry.runner')._set_source({
        now = clock.monotonic,
        scheduler_now = clock.scheduler_now,
        sleep = clock.sleep,
    })
    helper.random(1)
end

--- Заводит группу проверок с заново загруженными исходниками.
---
--- Исходники грузятся перед каждой проверкой: подменённые средства живут
--- в модуле, и не загруженный заново модуль принёс бы в следующую
--- проверку часы от предыдущей.
---@param name string Имя группы
---@param module_name string Какой модуль пакета проверяется
---@return table group
---@return table ctx Поля module, clock и logged, обновляемые перед проверкой
function helper.group(name, module_name)
    local group = t.group(name)
    local journal = testing.capture_log()
    local ctx = { logged = journal.logged }

    group.before_each(function()
        journal.forget()
        ctx.module = testing.load_sources(helper.MODULES, module_name)
        ctx.clock = testing.clock()
        helper.arm(ctx.clock)
    end)

    group.after_each(function()
        testing.unload_sources(helper.MODULES)
    end)

    return group, ctx
end

--- Действие, отказывающее названное число раз подряд, а потом удачное.
---@param failures number Сколько раз отказать; math.huge — отказывать всегда
---@param err any Чем отказывать
---@return fun(context: table): any, any action
---@return table seen Аргументы, которые действие видело на каждой попытке
function helper.flaky(failures, err)
    local seen = {}

    return function(context)
        table.insert(seen, context)

        if #seen <= failures then
            return nil, err
        end

        return 'готово'
    end,
        seen
end

--- Приёмник, запоминающий всё, что ему сказали.
---@return fun(info: table) on_attempt
---@return table[] seen
function helper.recorder()
    local seen = {}

    return function(info)
        table.insert(seen, info)
    end, seen
end

--- Сверяет начало текста точно.
---
--- Нужно отказам о NaN: сам NaN печатается на разных сборках по-разному
--- («nan», «-nan»), а всё, что стоит перед ним, обязано совпасть буква
--- в букву — вхождение текста не заметило бы лишней приставки впереди.
---@param text any
---@param head string
function helper.assert_starts(text, head)
    t.assert_equals(tostring(text):sub(1, #head), head)
end

--- Зовёт `new` из куска с именем `caller`.
---
--- Бросок негодных настроек показывает на строку того, кто заводит ведро
--- или размыкатель, и по имени куска это видно в тексте целиком: номер
--- строки самой проверки съезжал бы с каждой правкой файла. Вызов — не
--- хвостовой: хвостовой ушёл бы со стека, и место съехало бы на кадр.
local from_caller = assert(load('return function(new, opts) local made = new(opts) return made end', '=caller'))()

--- Текст, которым `new` бросил на названных настройках.
---@param new fun(opts: any): any
---@param opts any
---@return string
function helper.thrown(new, opts)
    local ok, err = pcall(from_caller, new, opts)

    t.assert_equals(ok, false, 'настройки приняли то, что принимать нельзя')

    return tostring(err)
end

--- Исход попытки под названным номером; его отсутствие — ошибка проверки.
---@param seen table[]
---@param index integer
---@return table
function helper.at(seen, index)
    return (assert(seen[index], ('о попытке №%d никто не сказал'):format(index)))
end

return helper
