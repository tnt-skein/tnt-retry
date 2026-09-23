--- Правила значений настроек: текст отказа либо nil.
---
--- Настройки в пакете проверяют трое — повторы, ведро бюджета
--- и размыкатель, — и одна и та же беда у них обязана звучать одинаково:
--- «настройка window — целое число от 1» у размыкателя и «настройка
--- attempts — целое число от 1» у повторов. Правило, записанное в каждом
--- месте своё, разъехалось бы с первой же правкой одного из них.
---
--- Здесь ничего не бросают: повторы отказывают парой `nil, err`, ведро
--- и размыкатель бросают, и способ отказа выбирает тот, кто зовёт правило.
---
--- Границы записаны сравнением «годится», а не «не годится»: сравнение
--- с NaN всегда ложно, и так он не проходит ни одну из них. Граница,
--- записанная отрицанием (`value < 0`), пропустила бы NaN молча, а пауза
--- или срок длиной NaN сломали бы повтор посреди аварии.

local Module = {}

--- Текст отказа о значении настройки.
---@param name string Имя настройки
---@param expected string Чего ждали
---@param value any Что пришло
---@return string
function Module.refusal(name, expected, value)
    return ('настройка %s — %s, а пришло: %s'):format(name, expected, tostring(value))
end

--- Целое число от единицы: попытки, исходы, пробы.
---
--- Бесконечность сюда не проходит: остаток её деления на единицу — NaN.
---@param value any
---@param name string
---@return string|nil
function Module.count(value, name)
    if type(value) == 'number' and value >= 1 and value % 1 == 0 then
        return nil
    end

    return Module.refusal(name, 'целое число от 1', value)
end

--- Доля больше нуля и не больше единицы.
---
--- Ноль — не доля, а выключатель: размыкатель с порогом ноль размыкает
--- цепь от любого отказа, а ведро, которому удача не возвращает ничего,
--- пустеет навсегда. Больше единицы — не доля вовсе: такой порог
--- не достигается никогда, и размыкатель не размыкается.
---@param value any
---@param name string
---@return string|nil
function Module.share(value, name)
    if type(value) == 'number' and value > 0 and value <= 1 then
        return nil
    end

    return Module.refusal(name, 'доля больше 0 и не больше 1', value)
end

--- Срок в секундах больше нуля.
---@param value any
---@param name string
---@return string|nil
function Module.seconds(value, name)
    if type(value) == 'number' and value > 0 then
        return nil
    end

    return Module.refusal(name, 'срок в секундах больше нуля', value)
end

--- Функция, если её вообще задали.
---@param value any
---@param name string
---@return string|nil
function Module.callable(value, name)
    if value == nil or type(value) == 'function' then
        return nil
    end

    return ('настройка %s должна быть функцией'):format(name)
end

return Module
