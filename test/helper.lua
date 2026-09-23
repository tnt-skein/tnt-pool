--- Общие средства тестов пула.
---
--- Исходники читаются с диска, а не через `require`: у Tarantool свой
--- загрузчик `.rocks`, он идёт раньше `package.path` и подсунул бы
--- установленную копию пакета, если она есть. Проверки тогда шли бы
--- против вчерашнего кода, а покрытие считалось бы по нему. Зависимости
--- пакета — `tnt.must`, `tnt.clock`, `tnt.log`, `tnt.loop`,
--- `tnt.external` — берутся из `.rocks` обычным `require`: проверяется
--- этот пакет, а не они. Ловушка журнала встаёт и на установленный
--- `tnt.log` — тот же экземпляр, которым пишет пул.
---
--- Оснастка в `test/testing/` — загрузчик исходников, часы, которые
--- двигает проверка, и ловушка журнала — грузится так же и один раз
--- на процесс: второй экземпляр загрузчика не знал бы, что вытеснил
--- первый, и не вернул бы вытесненное на место.
---
--- Проверки пула берут всё через помощник, а не из оснастки напрямую:
--- помощник — единственное, чем файл проверок отличается от того же файла
--- в наборе, где пакет живёт рядом со своими зависимостями.

local fiber = require('fiber')
local fio = require('fio')

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
    { name = 'tnt.pool.settings', path = 'tnt/pool/settings.lua' },
    { name = 'tnt.pool.opening', path = 'tnt/pool/opening.lua' },
    { name = 'tnt.pool.waiters', path = 'tnt/pool/waiters.lua' },
    { name = 'tnt.pool', path = 'tnt/pool.lua' },
}

--- Модуль пакета из исходников.
---
--- Заново на каждую проверку: общий пул живёт в модуле, и пул, оставленный
--- соседней проверкой, сделал бы порядок проверок частью их смысла.
---@param name string Какой модуль отдать: tnt.pool, tnt.pool.settings
---@return any
function helper.load(name)
    return testing.load_sources(helper.MODULES, name)
end

--- Ловушка журнала на время проверки — на всех экземплярах `tnt-log`.
---
--- Отказ, который никого не сорвал, — неудачное закрытие, сорванная
--- уборка, утёкшее соединение, — виден только записью журнала.
---@return TntTestingJournal
function helper.capture_log()
    return testing.capture_log()
end

--- Убирает исходники и возвращает то, что они вытеснили.
function helper.unload()
    testing.unload_sources(helper.MODULES)
end

--- Все настройки пула по порядку — так их перечисляет отказ об опечатке.
helper.KNOWN_SETTINGS = 'alive, close, idle_timeout, leak_timeout, max_lifetime, name, '
    .. 'open, open_cooldown, reset, size, sweep_interval, wait_timeout'

--- Часы, которые двигает проверка, и средства пула от них.
---
--- Часы — двойник оснастки. Пятисекундный срок, проверенный настоящим
--- сном, стоит проверке пять секунд, а таких сроков в пуле десяток;
--- условная переменная двойника, не получившая побудки, сама двигает часы
--- на весь запрошенный срок — для пула это неотличимо от сна, а проверка
--- мгновенна и точна до доли секунды. Внешней зависимости часы уходят
--- полями, а не целиком: незнакомое имя объявление отвергает.
---@param opts TntTestingClockOptions|nil С какого мига идут часы и на сколько планировщик просыпает срок
---@return TntTestingClock clock
---@return table source Средства внешних зависимостей
function helper.clock(opts)
    local clock = testing.clock(opts)

    return clock, { monotonic = clock.monotonic, cond = clock.cond }
end

--- Условная переменная, у которой ожидание срывается.
---
--- Отмена файбера выходит из `wait` исключением, а не ответом, и подделать
--- это иначе нечем. Поведение пула на сорванном ожидании стоит проверять
--- отдельно: это единственный случай, когда взявший уходит, не дождавшись
--- ни соединения, ни своего срока.
---@param reason string Чем сорвалось
---@return fun(): table
function helper.broken_cond(reason)
    return function()
        return {
            wait = function()
                error(reason, 0)
            end,

            signal = function() end,

            broadcast = function() end,
        }
    end
end

--- Служба, соединения с которой считает сама проверка.
---
--- Соединение — таблица со своим номером: по номеру видно, то же самое
--- выдали или новое. Закрытые складываются отдельным списком — иначе
--- нечем проверить, что пул за собой убирает, а незакрытый сеанс
--- на той стороне живёт и занимает чужой предел соединений.
---@param opts table|nil
---@return table
function helper.service(opts)
    local given = opts or {}

    local service = {
        --- Сколько раз пул просил открыть соединение.
        attempts = 0,
        --- Какой остаток срока пул давал каждой попытке.
        lefts = {},
        --- Сколько соединений выдано.
        opened = 0,
        --- Номера закрытых, в порядке закрытия.
        closed = {},
        --- Живы ли выданные соединения.
        live = true,
        --- Сколько ближайших открытий отказывают; `math.huge` — все.
        failures = given.failures or 0,
        --- Уступает ли `open` управление: без этого одновременность
        --- открытия проверить нечем — всё успевает случиться подряд.
        slow = given.slow or false,
        --- Чем отказывает открытие.
        reason = given.reason or 'служба не отвечает',
    }

    function service.open(left)
        service.attempts = service.attempts + 1
        table.insert(service.lefts, left)

        if service.slow then
            fiber.sleep(0)
        end

        if service.failures ~= 0 then
            service.failures = service.failures - 1

            return nil, service.reason
        end

        service.opened = service.opened + 1

        return { id = service.opened }
    end

    function service.close(conn)
        table.insert(service.closed, conn.id)
    end

    function service.alive()
        return service.live
    end

    return service
end

--- Пул к этой службе.
---
--- Живость по умолчанию не проверяется: `alive` есть не у всякого клиента,
--- и путь без него — тот, по которому пул ходит чаще. Проверки, которым
--- нужна живость, просят её отдельно.
---@param service table
---@param opts table|nil Что поменять в настройках
---@return any
function helper.pool_of(service, opts)
    local settings = {
        open = service.open,
        close = service.close,
        size = 2,

        -- Такт уборки заводит фибер, который проверке только мешает:
        -- она зовёт уборку сама и тогда, когда ей нужно.
        sweep_interval = 0,
    }

    for key, value in pairs(opts or {}) do
        settings[key] = value
    end

    return testing.module('tnt.pool').new(settings)
end

return helper
