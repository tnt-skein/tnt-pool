rockspec_format = '3.0'

package = 'tnt-pool'
version = 'scm-1'

source = {
    url = 'git+https://github.com/tnt-skein/tnt-pool.git',
    branch = 'main',
}

description = {
    summary = 'Пул соединений для любого клиента: честная очередь, сроки, отказы открытия',
    detailed = [[
        Соединение с чужой службой стоит дорого в открытии и почти ничего
        в использовании. Открывать его на каждый запрос значит платить
        за рукопожатие и вход столько же, сколько за саму работу; держать
        одно на весь узел — выстроить все файберы в очередь к одной верёвке.

        Пакет не знает ни одного протокола: своеобразие клиента заперто
        в четырёх функциях — открыть, закрыть, проверить живость, сбросить
        перед возвратом, — поэтому один пул годится и драйверу базы,
        и сокету очереди, и клиенту SMTP.

        Ждущие стоят в честной очереди на условных переменных и не крутят
        цикл; срок ожидания обязателен, и open получает остаток этого срока
        аргументом. Отказ открытия не превращается ни в шторм
        переподключений, ни в зависание: пауза растёт с каждым отказом
        подряд, а отказ, помеченный retriable = false, отдаётся сразу.
        Соединение, на котором случилась ошибка, в пул не возвращается;
        удержанное дольше срока называется в журнале; stats показывает
        и мгновенное состояние, и накопленные счётчики.

        Зависит от tnt-must (проверка настроек), tnt-clock (монотонные
        часы), tnt-log (журнал), tnt-loop (такт уборки) и tnt-external
        (подмена часов и условной переменной в проверках). Покрытие строк
        и убитых мутантов — 100 %.
    ]],
    homepage = 'https://github.com/tnt-skein/tnt-pool',
    issues_url = 'https://github.com/tnt-skein/tnt-pool/issues',
    maintainer = 'tnt-skein',
    license = 'MIT',
    labels = { 'tarantool', 'pool', 'connection-pool', 'connections', 'fiber', 'database' },
}

dependencies = {
    'lua >= 5.1',
    'tnt-must',
    'tnt-clock',
    'tnt-log',
    'tnt-loop',
    'tnt-external',
}

build = {
    type = 'builtin',
    modules = {
        ['tnt.pool'] = 'tnt/pool.lua',
        ['tnt.pool.opening'] = 'tnt/pool/opening.lua',
        ['tnt.pool.settings'] = 'tnt/pool/settings.lua',
        ['tnt.pool.waiters'] = 'tnt/pool/waiters.lua',
    },
}
