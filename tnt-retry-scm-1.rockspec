rockspec_format = '3.0'

package = 'tnt-retry'
version = 'scm-1'

source = {
    url = 'git+https://github.com/tnt-skein/tnt-retry.git',
    branch = 'main',
}

description = {
    summary = 'Повторы неудавшихся действий: отступ с разбросом, срок, бюджет и размыкатель',
    detailed = [[
        Сеть отказывает ненадолго: узел перезапускается, лидер меняется,
        сервер на секунду захлебнулся. Цикл «попытка, пауза, ещё попытка»
        пишет каждый сетевой клиент, и каждый пишет его чуть иначе —
        один забывает разброс и добивает вставший сервер, другой
        повторяет «неверный пароль». Здесь этот цикл один на всех.

        Отступ растёт степенью и размазан случаем из байтов ядра,
        классификатор решает, что вообще стоит повторять, — по полю
        retriable, по коду ответа, по словам отказа, — общий срок держит
        предел времени, а бюджет повторов и размыкатель не дают клиенту
        добивать лежащий сервис. Отказ — пара nil, err с последней
        причиной; опечатка в настройке — тоже отказ, а не умолчание.

        Зависит от tnt-must (текст отказа о незнакомой настройке),
        tnt-clock (монотонные часы, время планировщика и пауза), tnt-log
        (журнал) и tnt-external (подмена часов, паузы и случая
        в проверках): проверка минутного ожидания не занимает минуту.
        Покрытие строк и убитых мутантов — 100 %.
    ]],
    homepage = 'https://github.com/tnt-skein/tnt-retry',
    issues_url = 'https://github.com/tnt-skein/tnt-retry/issues',
    maintainer = 'tnt-skein',
    license = 'MIT',
    labels = { 'tarantool', 'retry', 'backoff', 'jitter', 'circuit-breaker', 'resilience' },
}

dependencies = {
    'lua >= 5.1',
    'tnt-must',
    'tnt-clock',
    'tnt-log',
    'tnt-external',
}

build = {
    type = 'builtin',
    modules = {
        ['tnt.retry'] = 'tnt/retry.lua',
        ['tnt.retry.attempt'] = 'tnt/retry/attempt.lua',
        ['tnt.retry.backoff'] = 'tnt/retry/backoff.lua',
        ['tnt.retry.breaker'] = 'tnt/retry/breaker.lua',
        ['tnt.retry.budget'] = 'tnt/retry/budget.lua',
        ['tnt.retry.classify'] = 'tnt/retry/classify.lua',
        ['tnt.retry.options'] = 'tnt/retry/options.lua',
        ['tnt.retry.rule'] = 'tnt/retry/rule.lua',
        ['tnt.retry.runner'] = 'tnt/retry/runner.lua',
    },
}
