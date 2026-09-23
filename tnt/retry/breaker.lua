--- Размыкатель: перестать звонить туда, где не берут трубку.
---
--- Повторы лечат отказ одного вызова. Они не лечат лежащий сервис: пока
--- он лежит, каждый вызов проходит весь свой набор попыток, честно ждёт
--- между ними и честно отказывает — а вызывающий платит за это файбером,
--- сроком и временем человека, который ждёт ответа панели. Сто вызовов
--- по три попытки — это триста обращений к тому, про кого уже после
--- первого десятка было ясно всё.
---
--- Размыкатель живёт в этом пакете, а не отдельным пакетом, по одной
--- причине: он судит об исходе теми же уликами, что и повторы. «Неверный пароль»
--- для него — здоровый ответ здорового сервера, и отдельный пакет
--- либо повторил бы за `classify` весь список подсказок, либо всё равно
--- зависел бы от `tnt.retry`. Второе — это тот же пакет, только с лишней
--- зависимостью; первое — два списка, которые однажды разойдутся.
---
--- Три состояния:
---
---   * замкнут (closed) — вызовы идут, исходы считаются;
---   * разомкнут (open) — вызовы не идут вовсе, отказ мгновенный;
---   * полуоткрыт (half_open) — проходит несколько проб, и по ним
---     решается, замкнуться обратно или размыкаться снова.
---
--- Полуоткрытое состояние — главное в устройстве. Без него размыкатель
--- либо не замыкается никогда, либо пускает поток целиком и снова кладёт
--- едва вставший сервис.
---
--- Считаются не все отказы, а только те, что говорят о сервере. «Неверный
--- пароль» означает, что сервер жив, отвечает и разобрал запрос;
--- размыкать цепь от чужой опечатки в пароле — значит уронить работу
--- всех остальных. Поэтому исход считается здоровым, если вызов удался
--- **или** отказ не из тех, что повторяют.
---
--- Окно считается по числу вызовов, а не по времени. У редко зовущего
--- клиента окно по времени почти всегда пусто, и решение принимается
--- по одному-двум исходам — то есть по шуму.
---
--- Чем поступились: счётчик живёт в процессе и ничего не знает о соседних
--- узлах. Каждый узел размыкает свою цепь сам и на своих наблюдениях;
--- общего мнения о здоровье сервиса здесь нет и не будет — за ним ходят
--- в диагностику кластера, а не в клиента.
---
--- Негодная настройка — бросок в `new`, а не пара `nil, err`. Размыкатель
--- заводят прямо в настройках повторов (`breaker = retry.breaker.new(...)`),
--- и `nil` из пары молча превратился бы там в «без размыкателя» — ровно
--- та защита, которую настраивали, пропала бы без единого слова.

local attempt = require('tnt.retry.attempt')
local classify = require('tnt.retry.classify')
local rule = require('tnt.retry.rule')

local clock = require('tnt.clock')
local external = require('tnt.external')

--- Проверки по имени без броска: отсюда текст отказа о незнакомой настройке.
local explain = require('tnt.must').explain

local log = require('tnt.log').new('tnt.retry')

local Module = {}

--- Состояния цепи.
Module.CLOSED = 'closed'
Module.OPEN = 'open'
Module.HALF_OPEN = 'half_open'

--- Доля отказов, после которой цепь размыкается.
---
--- Половина: сервис, отказывающий каждому второму, уже не сервис.
Module.DEFAULT_THRESHOLD = 0.5

--- Сколько последних исходов помнить.
Module.DEFAULT_WINDOW = 20

--- Сколько исходов должно набраться до первого решения.
---
--- Десять: два отказа из двух — это не доля, это совпадение.
Module.DEFAULT_MIN_CALLS = 10

--- Сколько молчать, прежде чем пробовать снова.
---
--- Полминуты: столько занимает перезапуск процесса или смена лидера,
--- то есть самое частое, что чинит такую беду само.
Module.DEFAULT_RESET_TIMEOUT = 30

--- Сколько проб пускать в полуоткрытом состоянии.
Module.DEFAULT_PROBES = 1

--- Как звать службу в отказе, если звать её никак не сказали.
local DEFAULT_NAME = 'служба'

--- Внешние средства: часы.
---
--- Монотонные: срок молчания меряется длительностью, а перевод стенных
--- часов назад продлил бы его на разницу — то есть разомкнул бы цепь
--- на час из-за поправки от сервера времени.
local source = external.install(Module, { now = clock.monotonic })

---@class TntRetryBreaker
---@field name string Кого зовём
---@field threshold number Доля отказов, после которой размыкаем
---@field window integer Сколько исходов помним
---@field min_calls integer Сколько исходов нужно для решения
---@field reset_timeout number Сколько молчим перед пробой
---@field probes integer Сколько проб пускаем
---@field retriable fun(err: any): boolean Что считать бедой сервера
---@field current string Состояние цепи
---@field opened_at number|nil Когда разомкнули; у замкнутой цепи не задано
---@field probes_left integer Сколько проб ещё пустим
---@field outcomes boolean[] Окно последних исходов
---@field failures integer Сколько из них неудачных
local Breaker = {}
Breaker.__index = Breaker

---@class TntRetryBreakerOptions
---@field name string|nil Кого зовём; попадает в текст отказа
---@field threshold number|nil Доля отказов, после которой размыкаем
---@field window integer|nil Сколько исходов помним
---@field min_calls integer|nil Сколько исходов нужно для решения
---@field reset_timeout number|nil Сколько молчим перед пробой
---@field probes integer|nil Сколько проб пускаем
---@field retriable (fun(err: any): boolean)|nil Что считать бедой сервера

--- Как настройки размыкателя называются в отказе.
local TITLE = 'настройки размыкателя'

--- Настройки размыкателя для `must.explain.options`: ключ знаком,
--- а значение проверяет `complaint` своим текстом — тем же, каким
--- повторы говорят о своих значениях.
---@type table<string, string>
local KNOWN = {
    name = '?',
    threshold = '?',
    window = '?',
    min_calls = '?',
    reset_timeout = '?',
    probes = '?',
    retriable = '?',
}

--- Проверяет имя службы.
---@param name any
---@return string|nil
local function wrong_name(name)
    if type(name) == 'string' then
        return nil
    end

    return rule.refusal('name', 'имя службы строкой', name)
end

--- Проверяет, вмещает ли окно столько исходов, сколько ждут решения.
---
--- `min_calls` больше `window` — противоречие, а не вкус: окно помнит
--- ровно `window` исходов, решения ждут `min_calls`, и цепь с такими
--- настройками не разомкнётся никогда, как бы служба ни лежала.
---@param settings table Настройки, у которых оба числа уже проверены
---@return string|nil
local function wrong_window(settings)
    if settings.min_calls > settings.window then
        return 'настройка min_calls больше window: окно не вместит столько исходов, и цепь не разомкнётся'
    end

    return nil
end

--- Что не так с собранными настройками — уже с заголовком; nil — всё
--- в порядке.
---@param settings table
---@return string|nil
local function complaint(settings)
    local wrong = wrong_name(settings.name)
        or rule.share(settings.threshold, 'threshold')
        or rule.count(settings.window, 'window')
        or rule.count(settings.min_calls, 'min_calls')
        or rule.seconds(settings.reset_timeout, 'reset_timeout')
        or rule.count(settings.probes, 'probes')
        or rule.callable(settings.retriable, 'retriable')
        or wrong_window(settings)

    if wrong == nil then
        return nil
    end

    return ('%s: %s'):format(TITLE, wrong)
end

--- Настройки размыкателя поверх умолчаний.
---
--- Проверяется то, что вышло из слияния: умолчание `min_calls` спорит
--- с заданным `window`, и увидеть это можно только вместе. `false`
--- вместо числа — не «умолчание», а ошибка, и молча её не заменить.
--- `box.NULL` — «настройки нет», как и в слиянии настроек повторов: так
--- приходит `null` из YAML и JSON, и судьёй `retriable` он не станет.
---@param opts any
---@return table|nil settings
---@return string|nil err
local function settings_of(opts)
    local given = opts or {}
    local stray = explain.options(given, TITLE, KNOWN)

    if stray ~= nil then
        return nil, stray
    end

    local settings = {
        name = DEFAULT_NAME,
        threshold = Module.DEFAULT_THRESHOLD,
        window = Module.DEFAULT_WINDOW,
        min_calls = Module.DEFAULT_MIN_CALLS,
        reset_timeout = Module.DEFAULT_RESET_TIMEOUT,
        probes = Module.DEFAULT_PROBES,
        retriable = classify.of,
    }

    for key, value in pairs(given) do
        if value ~= nil then
            settings[key] = value
        end
    end

    local wrong = complaint(settings)

    if wrong ~= nil then
        return nil, wrong
    end

    return settings
end

--- Собирает размыкатель. Начинает замкнутым: пока ничего не известно,
--- запрещать нечего.
---
--- Незнакомый ключ и негодное значение — бросок с местом того, кто
--- заводит размыкатель: `{ treshold = 0.1 }` иначе молча дал бы порог
--- по умолчанию, а строка вместо числа сломала бы первый же вызов,
--- посреди работы.
---@param opts TntRetryBreakerOptions|nil
---@return TntRetryBreaker
function Module.new(opts)
    local settings, wrong = settings_of(opts)

    if settings == nil then
        error(wrong, 2)
    end

    local breaker = setmetatable(settings, Breaker)

    breaker:reset()

    return breaker
end

--- Забывает окно исходов.
---
--- Окно чистится на каждой смене состояния: исходы, собранные до
--- размыкания, описывают уже другой сервис — тот, который лежал.
function Breaker:forget()
    self.outcomes = {}
    self.failures = 0
end

--- Переводит цепь в названное состояние и забывает наблюдения.
---@param state string
function Breaker:switch(state)
    self.current = state
    self.probes_left = 0
    self:forget()
end

--- Забывает всё и замыкает цепь: размыкатель как из коробки.
function Breaker:reset()
    self:switch(Module.CLOSED)
end

--- Размыкает цепь.
function Breaker:trip()
    self.opened_at = source().now()
    self:switch(Module.OPEN)
    log.warn('размыкатель разомкнут', { service = self.name, silence = self.reset_timeout })
end

--- Замыкает цепь обратно.
function Breaker:close()
    self:switch(Module.CLOSED)
    log.info('размыкатель замкнут', { service = self.name })
end

--- Сколько осталось молчать.
---@return number Секунды
function Breaker:silence_left()
    -- Отметка размыкания есть только у разомкнутой цепи: замкнутая
    -- никогда не молчала, и спрашивать у неё остаток нечего.
    if self.current ~= Module.OPEN then
        return 0
    end

    return math.max(0, self.reset_timeout - (source().now() - self.opened_at))
end

--- В каком состоянии цепь прямо сейчас.
---
--- Переход «разомкнут → полуоткрыт» делается здесь, а не по таймеру:
--- таймер — это файбер, который надо заводить, будить и гасить,
--- а размыкатель, которого никто не зовёт, не обязан ничего делать.
---@return string
function Breaker:state()
    if self.current == Module.OPEN and source().now() - self.opened_at >= self.reset_timeout then
        self.current = Module.HALF_OPEN
        self.probes_left = self.probes
    end

    return self.current
end

--- Пропускает ли цепь вызов.
---@return boolean allowed
---@return string|nil err Почему не пропускает
function Breaker:allow()
    local state = self:state()

    if state == Module.CLOSED then
        return true
    end

    if state == Module.OPEN then
        local refusal =
            'размыкатель разомкнут: %s не отвечает, проба через %.1f с'
        return false, refusal:format(self.name, self:silence_left())
    end

    if self.probes_left > 0 then
        self.probes_left = self.probes_left - 1

        return true
    end

    return false, ('размыкатель на пробе: %s ещё проверяется'):format(self.name)
end

--- Запоминает исход в окне последних.
---@param healthy boolean
function Breaker:remember(healthy)
    table.insert(self.outcomes, healthy)

    if not healthy then
        self.failures = self.failures + 1
    end

    -- Окно помнит ровно `window` исходов: самый старый уходит, и вместе
    -- с ним — его вклад в долю отказов.
    if #self.outcomes > self.window then
        if not table.remove(self.outcomes, 1) then
            self.failures = self.failures - 1
        end
    end
end

--- Набралось ли отказов на размыкание.
---
--- Пока исходов меньше `min_calls`, решения нет вовсе, и доля
--- не считается. Одно выражение, а не ранний `return false`: зовущий
--- читает ответ только как истину или ложь, и у отдельной ветки мутант
--- `nil` был бы неотличим.
---@return boolean
function Breaker:overwhelmed()
    local calls = #self.outcomes

    return calls >= self.min_calls and self.failures / calls >= self.threshold
end

--- Разбирает исход пробы в полуоткрытом состоянии.
---
--- Первая удачная проба замыкает цепь, первая неудачная размыкает снова.
--- Требовать нескольких удач подряд смысла нет: сервис, который встал,
--- ответит и на второй вызов, а сервис, который не встал, отсеется
--- окном исходов — оно считает долю отказов с первой же минуты после
--- замыкания. `probes` поэтому говорит не «сколько удач ждём», а
--- «сколько вызовов пускаем, пока проверяем».
---@param healthy boolean
function Breaker:judge_probe(healthy)
    if healthy then
        self:close()

        return
    end

    self:trip()
end

--- Записывает исход вызова.
---@param ok boolean Удался ли вызов
---@param err any Причина отказа
function Breaker:record(ok, err)
    local healthy = ok or not self.retriable(err)

    if self:state() == Module.HALF_OPEN then
        self:judge_probe(healthy)

        return
    end

    self:remember(healthy)

    if not healthy and self:overwhelmed() then
        self:trip()
    end
end

--- Выполняет действие через размыкатель, без повторов.
---
--- Нужен тому, кто хочет защиту от лежащего сервиса без повторов вообще:
--- запись в чужой журнал или отправка метрики повтора не стоят, а вот
--- ждать соединения с мёртвым получателем на каждом вызове — стоит.
---@param action fun(context: table): any, any
---@return any value
---@return any err
function Breaker:call(action)
    local allowed, refusal = self:allow()

    if not allowed then
        return nil, refusal
    end

    -- Попытка здесь ровно одна, и действие вправе про это знать: аргумент
    -- у него тот же, что и в цикле повторов, просто без срока и пауз.
    local ok, value, err = attempt.once(action, { attempt = 1, elapsed = 0 })

    self:record(ok, err)

    return value, err
end

--- Что видно снаружи. Ни адресов, ни ключей здесь нет.
---@return table
function Breaker:status()
    return {
        name = self.name,
        state = self:state(),
        calls = #self.outcomes,
        failures = self.failures,
        threshold = self.threshold,
        min_calls = self.min_calls,
        probes_left = self.probes_left,
        silence_left = self:silence_left(),
    }
end

return Module
