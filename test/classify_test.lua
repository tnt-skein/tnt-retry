--- Проверки приговора отказу: что повторяют, а что нет.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g, ctx = helper.group('tnt.retry.classify', 'tnt.retry.classify')

--- Приговор отказу; короткая запись, потому что проверок приговора много.
---@param err any
---@return string
local function verdict(err)
    return ctx.module.verdict(err)
end

g.test_word_of_the_caller_beats_every_other_clue = function()
    -- Код 404 и слова «not found» кричат «постоянный», но тот, кто
    -- разбирал протокол, сказал иначе — и спорить с ним незачем.
    t.assert_equals(verdict({ retriable = true, status = 404, message = 'not found' }), 'transient')
    t.assert_equals(verdict({ retriable = false, status = 503 }), 'permanent')
end

g.test_server_errors_are_worth_repeating = function()
    t.assert_equals(verdict({ status = 500 }), 'transient')
    t.assert_equals(verdict({ status_code = 503 }), 'transient')
    t.assert_equals(verdict({ http_status = 599 }), 'transient')
end

g.test_request_errors_are_not_worth_repeating = function()
    t.assert_equals(verdict({ status = 400 }), 'permanent')
    t.assert_equals(verdict({ status = 401 }), 'permanent')
    t.assert_equals(verdict({ status = 499 }), 'permanent')
    t.assert_equals(verdict({ status = 600 }), 'permanent')
end

g.test_codes_asking_for_a_repeat_are_repeated_despite_their_rank = function()
    t.assert_equals(verdict({ status = 408 }), 'transient')
    t.assert_equals(verdict({ status = 425 }), 'transient')
    t.assert_equals(verdict({ status = 429 }), 'transient')
end

g.test_server_errors_that_time_does_not_cure_are_not_repeated = function()
    t.assert_equals(verdict({ status = 501 }), 'permanent')
    t.assert_equals(verdict({ status = 505 }), 'permanent')
end

g.test_own_error_code_of_tarantool_is_not_a_response_code = function()
    -- У ошибок Tarantool поле `code` своё (ER_*), и 77 там значит
    -- не «77 по HTTP»: читать его как код ответа нельзя.
    t.assert_equals(ctx.module.code_of({ code = 77 }), nil)
    t.assert_equals(ctx.module.code_of('503 сервер занят'), nil)
    t.assert_equals(ctx.module.code_of({ status = 'сломано' }), nil)
    t.assert_equals(ctx.module.code_of({ status = 503 }), 503)
end

g.test_words_of_a_permanent_refusal_stop_the_repeats = function()
    t.assert_equals(verdict('неверный пароль для dev@example.org'), 'permanent')
    t.assert_equals(verdict('Доступ запрещён'), 'permanent')
    t.assert_equals(verdict('permission denied'), 'permanent')
    t.assert_equals(verdict("attempt to index a nil value (field 'body')"), 'permanent')
end

g.test_words_of_a_transient_refusal_ask_for_a_repeat = function()
    t.assert_equals(verdict('сервер молчит'), 'transient')
    t.assert_equals(verdict('connection refused'), 'transient')
    t.assert_equals(verdict('can not write to read-only instance'), 'transient')
    t.assert_equals(verdict('no quorum'), 'transient')
end

g.test_capital_russian_letters_do_not_hide_the_refusal = function()
    -- `string.lower` в LuaJIT кириллицу не трогает, а сообщения приходят
    -- и с большой буквы: «Неверный пароль» обязан читаться так же.
    t.assert_equals(verdict('Неверный пароль'), 'permanent')
    t.assert_equals(verdict('НЕВЕРНЫЙ ПАРОЛЬ'), 'permanent')
    t.assert_equals(verdict('Сервер молчит'), 'transient')
    t.assert_equals(verdict('Узел недоступен'), 'transient')

    table.insert(ctx.module.transient, 'ёмкость очереди')
    t.assert_equals(verdict('Ёмкость очереди кончилась'), 'transient')
end

g.test_hint_of_a_refusal_is_not_a_piece_of_a_hint = function()
    -- «not implemented» — отказ, «implemented» — не отказ вовсе.
    -- Подсказка, потерявшая отрицание, начала бы запрещать повторы
    -- по слову «сделано».
    t.assert_equals(verdict('501 not implemented'), 'permanent')
    t.assert_equals(verdict('feature implemented in 3.0'), 'unknown')
end

g.test_permanent_words_are_looked_at_first = function()
    -- «Время ожидания» зовёт повторять, «аутентификация» — не зовёт.
    -- Лишний раз не повторить пароль дешевле, чем повторить его десять раз.
    t.assert_equals(verdict('время ожидания аутентификации истекло'), 'permanent')
end

g.test_refusal_without_clues_stays_unknown_and_is_repeated = function()
    t.assert_equals(verdict('что-то пошло не так'), 'unknown')
    t.assert_equals(verdict(nil), 'unknown')
    t.assert_equals(ctx.module.of('что-то пошло не так'), true)
    t.assert_equals(ctx.module.strict('что-то пошло не так'), false)
end

g.test_refusal_is_read_out_of_message_and_err_fields = function()
    t.assert_equals(verdict({ message = 'connection reset by peer' }), 'transient')
    t.assert_equals(verdict({ err = 'invalid credentials' }), 'permanent')
    t.assert_equals(
        verdict(setmetatable({}, {
            __tostring = function()
                return 'сеть пропала'
            end,
        })),
        'transient'
    )
end

g.test_refusal_whose_reading_throws_does_not_bring_down_the_verdict = function()
    -- Метатаблица чужого объекта вправе бросить, а классификатор,
    -- роняющий вызов, превращает беду сервера в беду узла.
    local angry = setmetatable({}, {
        __index = function()
            error('чужая метатаблица бросила')
        end,
    })

    t.assert_equals(verdict(angry), 'unknown')
end

g.test_fields_of_box_error_are_read_like_fields_of_a_table = function()
    -- `box.error` — cdata, а не таблица, и поля полезной нагрузки у него
    -- идут через метатаблицу. Не прочитав их, классификатор судил бы
    -- такой отказ только по тексту: «повтори» в поле проиграло бы
    -- «неверному паролю» в сообщении. Конструктор в аннотациях описан
    -- не полностью, поэтому берётся через промежуточную ссылку.
    ---@type any
    local box_error = box.error
    local told = box_error.new({ type = 'RemoteError', reason = 'неверный пароль', retriable = true })
    local busy = box_error.new({ type = 'HttpError', reason = 'занято', status = 503, retry_after = 7 })

    t.assert_equals(verdict(told), 'transient')
    t.assert_equals(ctx.module.code_of(busy), 503)
    t.assert_equals(ctx.module.delay_of(busy), 7)

    -- Без полей `box.error` судится текстом сообщения, как и прежде.
    t.assert_equals(verdict(box_error.new({ type = 'X', reason = 'Connection refused' })), 'transient')

    -- Прочая cdata полей не имеет, и чтение её поля бросает: такой отказ
    -- остаётся без улик, а не роняет приговор.
    t.assert_equals(verdict(1ULL), 'unknown')
end

g.test_open_list_of_hints_takes_words_of_the_caller = function()
    table.insert(ctx.module.transient, 'реплика догоняет')

    t.assert_equals(verdict('реплика догоняет лидера'), 'transient')
end

g.test_asked_delay_is_only_a_number_of_seconds = function()
    t.assert_equals(ctx.module.delay_of({ retry_after = 12 }), 12)
    t.assert_equals(ctx.module.delay_of({ retry_after = '12' }), 12)
    t.assert_equals(ctx.module.delay_of({ retry_after = 0 }), 0)
    t.assert_equals(ctx.module.delay_of({ retry_after = -1 }), nil)
    t.assert_equals(ctx.module.delay_of({ retry_after = 'Fri, 31 Dec 1999 23:59:59 GMT' }), nil)
    t.assert_equals(ctx.module.delay_of({}), nil)
    t.assert_equals(ctx.module.delay_of('сервер молчит'), nil)
end

g.test_default_repeats_everything_but_the_plainly_permanent = function()
    t.assert_equals(ctx.module.of('сервер молчит'), true)
    t.assert_equals(ctx.module.of('неверный пароль'), false)
    t.assert_equals(ctx.module.strict('сервер молчит'), true)
    t.assert_equals(ctx.module.strict('неверный пароль'), false)
end
