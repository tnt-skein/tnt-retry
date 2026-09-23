--- Решение о том, стоит ли повторять отказ.
---
--- Повтор помогает ровно в одном случае: когда в следующий раз выйдет то,
--- что не вышло сейчас. Сервер, ответивший «перегружен», через секунду
--- ответит иначе; сервер, ответивший «неверный пароль», ответит то же
--- самое и через час, и десять попыток превратятся в десять одинаковых
--- отказов, растянутых на минуту, — и в десять записей о неудачном входе
--- в чужом журнале безопасности.
---
--- Улик три, и смотрят их в этом порядке.
---
--- Первая — явное слово вызывающего: поле `retriable` в самом отказе.
--- Тот, кто разбирает протокол, знает про свой отказ больше всех,
--- и спорить с ним незачем.
---
--- Вторая — код ответа. Он берётся только из полей `status`, `status_code`
--- и `http_status` и никогда из текста. В HTTP 5xx — временная беда,
--- а 4xx — вина запроса; в SMTP ровно наоборот: 4xx просят повторить,
--- 5xx запрещают. Три цифры в начале строки не говорят, чей это протокол,
--- и угадавший неверно повторяет то, что повторять нельзя. Поле `code`
--- не берётся тоже: у ошибок Tarantool это собственный код (ER_*),
--- и 77 там значит не «77 по HTTP».
---
--- Третья — текст. Список подсказок открыт: `classify.permanent`
--- и `classify.transient` — обычные массивы, и пакет, знающий свои отказы,
--- дописывает в них свои слова, а не заводит свой классификатор. Слова
--- постоянных отказов смотрят первыми: «превышено время ожидания входа»
--- лучше не повторить лишний раз, чем повторить десять раз с тем же
--- паролем.
---
--- Когда улик нет, отказ считается временным и повторяется. Выбор
--- несимметричен нарочно. Лишний повтор постоянного отказа стоит двух
--- обращений и записи в журнале — предел попыток и срок не дадут ему
--- стоить больше. Неповторённый временный отказ стоит отказа всей работы,
--- и стоит его молча: пакет повторов, который не повторяет, выглядит
--- точно так же, как пакет повторов, которому нечего было повторять.
---
--- Чего здесь нет: догадок по коду в тексте, разбора даты в `Retry-After`
--- и знания о том, можно ли повторять само действие. Последнее важнее
--- прочего: «отказ временный» не значит «повторять безопасно». Перевод
--- денег, оборвавшийся после того, как сервер его принял, выглядит
--- временным отказом и повторяется вторым переводом. Неидемпотентное
--- действие повторяют только под ключом `tnt.once`.

local Module = {}

--- Приговор отказу.
Module.PERMANENT = 'permanent'
Module.TRANSIENT = 'transient'
Module.UNKNOWN = 'unknown'

--- Коды, которые повторяют вопреки разряду.
---
--- 408 — сервер сам не дождался запроса, 425 — «слишком рано, повтори»,
--- 429 — «слишком часто»: все три названы для того, чтобы их повторили.
local RETRIABLE_CODES = {
    [408] = true,
    [425] = true,
    [429] = true,
}

--- Коды, которые не повторяют вопреки разряду.
---
--- 501 и 505 — «не умею» и «не понимаю такой версии». Это 5xx, но чинит
--- их не время, а другой запрос или другой сервер.
local PERMANENT_CODES = {
    [501] = true,
    [505] = true,
}

--- Поля, в которых приходит код ответа.
local CODE_FIELDS = { 'status', 'status_code', 'http_status' }

--- Разряд кодов, которыми сервер признаётся в своей беде.
local SERVER_ERROR_FIRST = 500
local SERVER_ERROR_LAST = 599

--- Слова, после которых повторять бесполезно.
---
--- Учётные данные, права и запрос, который сервер не понял, временем
--- не лечатся. Сюда же ошибки самого Lua: `attempt to index a nil value` —
--- это не сеть, это код, и повтор выполнит ту же строку с тем же
--- результатом.
Module.permanent = {
    'неверный парол',
    'неверный логин',
    'аутентификац',
    'авториз',
    'доступ запрещ',
    'нет прав',
    'authentication failed',
    'invalid credentials',
    'permission denied',
    'access denied',
    'unauthorized',
    'forbidden',
    'bad request',
    'invalid argument',
    'not implemented',
    'attempt to index',
    'attempt to call',
    'attempt to concatenate',
    'attempt to perform',
    'attempt to compare',
}

--- Слова, после которых повторять стоит.
---
--- Сеть, сроки и занятость. Отдельно стоит `read-only instance`: узел
--- отказал не потому, что запрос плох, а потому, что лидер сейчас другой, —
--- смена лидера это и чинит, а больше ничего и не нужно.
Module.transient = {
    'сервер молчит',
    'сеть пропала',
    'соединение разорвано',
    'соединение закрыто',
    'не удалось соединиться',
    'узел недоступен',
    'время ожидания',
    'таймаут',
    'перегружен',
    'временно',
    'timed out',
    'timeout',
    'try again',
    'temporarily',
    'connection refused',
    'connection reset',
    'connection closed',
    'broken pipe',
    'unreachable',
    'no route to host',
    'closed by peer',
    'read-only instance',
    'is loading',
    'quorum',
}

--- Поле отказа, если его удалось прочитать.
---
--- Отказы приходят строкой, таблицей с полем и объектом `box.error`.
--- Последний — cdata, и поля его полезной нагрузки идут через метатаблицу;
--- отсечь cdata значило бы судить такой отказ одним текстом и не услышать
--- его `retriable`. У строки полей нет: индекс по ней ищет в библиотеке
--- строк, и найденное там — не поле отказа. Чтение обёрнуто в pcall:
--- чужая метатаблица вправе бросить, прочая cdata бросает на незнакомом
--- поле, а классификатор, роняющий вызов при разборе отказа, превращает
--- беду сервера в беду узла.
---@param err any
---@param name string
---@return any
local function field_of(err, name)
    local kind = type(err)

    if kind ~= 'table' and kind ~= 'cdata' then
        return nil
    end

    local read, value = pcall(function()
        return err[name]
    end)

    if read then
        return value
    end

    return nil
end

--- Русский алфавит заглавными и он же строчными, буква под букву.
---
--- `string.lower` в LuaJIT работает по таблице ASCII и кириллицу
--- не трогает: «Неверный пароль» остался бы с заглавной Н и не совпал бы
--- ни с одной подсказкой, а подсказки пишутся строчными. Перевод сделан
--- таблицей, а не арифметикой по байтам: диапазоны заглавных в UTF-8
--- разрывны — на середине алфавита меняется и ведущий байт, — а Ё стоит
--- вовсе не на своём месте. Буквы, выписанные подряд, видно глазом;
--- три диапазона с поправками — нет.
local UPPERCASE = 'АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ'
local LOWERCASE = 'абвгдеёжзийклмнопрстуфхцчшщъыьэюя'

--- Заглавная буква → строчная. Все русские буквы в UTF-8 двухбайтовые,
--- и в обоих регистрах, поэтому алфавиты идут парами байт: образец
--- режет их сам, и считать длину буквы не приходится.
local FOLD = {}
local lowercase = LOWERCASE:gmatch('..')

for uppercase in UPPERCASE:gmatch('..') do
    FOLD[uppercase] = lowercase()
end

--- Строчный вид текста, вместе с кириллицей.
---
--- Ведущий байт D0 — начало двухбайтовой буквы и в середине буквы
--- не встречается: продолжения в UTF-8 лежат в 80..BF. Пара, которой
--- в таблице нет, остаётся как была: замена `nil` для `gsub` значит
--- «не трогай».
---@param text string
---@return string
local function lowered(text)
    return (text:lower():gsub('\208.', function(pair)
        return FOLD[pair]
    end))
end

--- Текст отказа, каким бы он ни пришёл.
---@param err any
---@return string
local function text_of(err)
    if type(err) == 'string' then
        return err
    end

    if err == nil then
        return ''
    end

    local message = field_of(err, 'message') or field_of(err, 'err')

    if type(message) == 'string' then
        return message
    end

    return tostring(err)
end

--- Первая подсказка из списка, которая есть в тексте, либо nil.
---
--- Отвечает найденной подсказкой, а не «да» или «нет»: зовущие смотрят
--- только, нашлась ли она, и у ответа `false` мутант `nil` был бы
--- неотличим.
---@param text string
---@param hints string[]
---@return string|nil
local function mentioned(text, hints)
    for _, hint in ipairs(hints) do
        -- Поиск подстрокой, а не образцом: в подсказках есть дефис
        -- («read-only instance»), а в образцах Lua дефис — это
        -- ленивый повтор, и такая подсказка не нашла бы себя саму.
        -- Начало поиска — nil, то есть с начала текста: у числа 1 мутанты
        -- `0` и `1-1` ищут с того же места, и отличить их нечем.
        local at = text:find(hint, nil, true)

        if at ~= nil then
            return hint
        end
    end

    return nil
end

--- Код ответа, если отказ его принёс.
---@param err any
---@return number|nil
function Module.code_of(err)
    for _, field in ipairs(CODE_FIELDS) do
        local code = field_of(err, field)

        if type(code) == 'number' then
            return code
        end
    end

    return nil
end

--- Сколько сервер попросил подождать, если попросил.
---
--- Только число секунд. HTTP разрешает в `Retry-After` и дату, но дата
--- меряется часами сервера, а они расходятся с нашими — разобрав её,
--- пакет ждал бы по чужим часам и ошибался на всю разницу.
---@param err any
---@return number|nil Секунды
function Module.delay_of(err)
    local asked = tonumber(field_of(err, 'retry_after'))

    if asked == nil or asked < 0 then
        return nil
    end

    return asked
end

--- Приговор по коду ответа.
---@param code number
---@return string
local function by_code(code)
    if RETRIABLE_CODES[code] then
        return Module.TRANSIENT
    end

    if PERMANENT_CODES[code] then
        return Module.PERMANENT
    end

    if code >= SERVER_ERROR_FIRST and code <= SERVER_ERROR_LAST then
        return Module.TRANSIENT
    end

    return Module.PERMANENT
end

--- Приговор отказу: постоянный, временный или неизвестный.
---
--- Три значения, а не два, потому что «улик нет» — это не то же самое,
--- что «улики за повтор». Умолчание повторяет неизвестное; тому, кому
--- такая щедрость не по карману, годится `classify.strict`.
---@param err any
---@return string
function Module.verdict(err)
    local told = field_of(err, 'retriable')

    if type(told) == 'boolean' then
        return told and Module.TRANSIENT or Module.PERMANENT
    end

    local code = Module.code_of(err)

    if code ~= nil then
        return by_code(code)
    end

    local text = lowered(text_of(err))

    if mentioned(text, Module.permanent) ~= nil then
        return Module.PERMANENT
    end

    if mentioned(text, Module.transient) ~= nil then
        return Module.TRANSIENT
    end

    return Module.UNKNOWN
end

--- Стоит ли повторять этот отказ. Умолчание для `retry.run`.
---
--- Повторяется всё, кроме явно постоянного: неизвестный отказ считается
--- временным, потому что промолчавший клиент дороже лишнего обращения.
---@param err any
---@return boolean
function Module.of(err)
    return Module.verdict(err) ~= Module.PERMANENT
end

--- Повторять только то, про что известно, что это временно.
---
--- Годится там, где лишнее обращение дорого: чужой сервер со счётчиком
--- запросов, действие с побочным следом, сеть, за которую платят.
---@param err any
---@return boolean
function Module.strict(err)
    return Module.verdict(err) == Module.TRANSIENT
end

return Module
