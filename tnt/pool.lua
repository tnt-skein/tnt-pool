--- Пул соединений: общий для всего, что держит соединение.
---
--- Соединение с чужой службой — postgres, mysql, mongo, redis, http —
--- стоит дорого в открытии и почти ничего в использовании. Открывать его
--- на каждый запрос значит платить за рукопожатие, разрешение имени и вход
--- столько же, сколько за саму работу; держать одно на весь узел — выстроить
--- все файберы в очередь к одной верёвке. Между этими крайностями и живёт
--- пул: несколько соединений, которые берут, возвращают и переоткрывают
--- по мере надобности.
---
--- Пакет не знает ни одного протокола и знать не должен. Всё своеобразие
--- клиента заперто в трёх функциях, которые он даёт при заведении пула:
--- `open` открывает соединение, `close` закрывает, `alive` отвечает, живо ли
--- оно ещё. Поэтому один и тот же пул годится и драйверу базы, и сокету
--- очереди, и клиенту, которого ещё не написали.
---
--- Решения, которые стоит знать заранее:
---
--- * **Срок ожидания обязателен.** Файбер, ждущий соединения без срока,
---   не ждёт никого: его не разбудит ни отказ службы, ни закрытие пула,
---   и заметить его можно только по тому, что запрос не ответил никогда.
---   Поэтому `wait_timeout` не может быть ни нулём, ни бесконечностью.
--- * **Ожидание не крутит цикл.** Ждущие стоят в честной очереди на
---   условных переменных и снимаются с планировщика совсем; соединение
---   достаётся первому в очереди, а не тому, кого планировщик поднял
---   раньше.
--- * **Отказ `open` не превращается ни в поток попыток, ни в зависание.**
---   Упавшая служба отказывает всем одинаково, и шторм переподключений
---   мешает ей подняться, — поэтому после отказа открытие останавливается
---   на паузу, удваивающуюся с каждым отказом подряд. Но и отдавать отказ
---   по первой же неудаче нельзя: служба, моргнувшая на полсекунды,
---   уронила бы все запросы разом. Поэтому взявший ждёт ровно свой срок,
---   получая внутри него несколько попыток, и уходит с причиной последней
---   из них — не раньше и не позже.
--- * **Отказ, который время не лечит, отдаётся сразу.** Неверный пароль
---   через полсекунды останется неверным, и ждать срока ради него незачем.
---   Такой отказ `open` помечает полем `retriable = false`, и взявший
---   получает его тут же и как есть — если ждать больше нечего: в пуле нет
---   ни одного соединения, которое могли бы вернуть или открыть.
--- * **Вход не длится дольше срока взявшего.** `open` получает остаток
---   этого срока аргументом: у многих клиентов своего срока входа нет, и вход
---   к молчащему серверу продлил бы `take` на всё время, пока тот молчит.
--- * **Соединение, на котором случилась ошибка, в пул не возвращается.**
---   Пул не умеет отличить отказ сети от ошибки разбора ответа, а соединение
---   в непонятном состоянии отравляет и всех следующих, кому достанется.
---   Поэтому `with` при ошибке внутри тела соединение выбрасывает.
--- * **Отказ — не ошибка, и соединение после него возвращается.** Пул
---   не видит транзакций: тело, вернувшее `nil, err` посреди своей
---   транзакции, отдало бы её следующему взявшему, и тот зафиксировал бы
---   чужую работу. На возврате такое соединение отсекает только `reset`,
---   поэтому тот, кто открывает транзакции, обязан его задать.
--- * **Тот, кто взял, обязан вернуть.** Не вернувший течёт: пул считает
---   соединение занятым навсегда и однажды перестаёт выдавать что-либо.
---   Поэтому основной способ пользоваться пулом — `with`, который вернёт
---   соединение в любом исходе, а `leak_timeout` находит тех, кто всё-таки
---   взял напрямую и забыл.
--- * **Не для `net.box`.** Оно мультиплексировано: одно соединение
---   обслуживает сколько угодно одновременных запросов, а предел на них —
---   `iproto.net_msg_max` — стоит на сервере и общий на все соединения.
---   Пул нужен соединению, которое обслуживает один запрос за раз: `pg`,
---   `mysql`, SMTP, сокет очереди. Замеры — в `docs/pool.md`.
---
--- Пользоваться так (на роке `pg`; почему именно так — в `docs/pool.md`):
---
---     local pg = require('pg')
---     local pool = require('tnt.pool')
---
---     -- conn_string — строка libpq со значениями в кавычках и с `\`
---     -- и `'`, экранированными обратной чертой: строку `pg.connect(dsn)`
---     -- рок не читает, а ключи вставляет без экранирования.
---     local p = pool.new({
---         open = function() return pg.connect({ conn_string = conn_string }) end,
---         close = function(c) if not pcall(c.close, c) then c.conn:close() end end,
---         alive = function(c) return (pcall(c.active, c)) end,
---         reset = function(c) return not c:active() end,
---         size = 8,
---     })
---
---     local rows, err = p:with(function(c)
---         return c:execute('select 1 as one')[1]
---     end)
---
---     p:close()

local fiber = require('fiber')

local clock = require('tnt.clock')
local loop = require('tnt.loop')
local external = require('tnt.external')
local opening_of = require('tnt.pool.opening')
local settings_of = require('tnt.pool.settings')
local waiters = require('tnt.pool.waiters')

local log = require('tnt.log').new('tnt.pool')

local Module = {}

--- Внешние средства: часы и условная переменная.
---
--- Часы монотонные: сроки меряются длительностью, а перевод стенных часов
--- назад посреди ожидания продлил бы его на разницу. Условная переменная
--- берётся той же внешней зависимостью, потому что без неё проверка пятисекундного срока
--- шла бы пять секунд.
local source = external.install(Module, {
    monotonic = clock.monotonic,
    cond = function()
        return fiber.cond()
    end,
})

--- Учётная запись соединения.
---
--- Заводится неполной: занятость, миг выдачи и след об утечке проставляет
--- выдача, а миг возвращения — возврат. Поэтому поля, за которые отвечают
--- они, объявлены пустыми: обещать здесь число значило бы обещать то, чего
--- в первый миг жизни записи ещё нет.
---@class TntPoolEntry
---@field conn any Само соединение
---@field created number Когда открыто, по монотонным часам
---@field idle_since number Когда легло в пул
---@field taken_at number Когда его взяли в последний раз
---@field busy boolean Занято ли сейчас
---@field uses integer Сколько раз выдавалось
---@field reported boolean Кричали ли уже об утечке этого удержания

---@class TntPoolCounters
---@field opened integer Сколько соединений открыто за всё время
---@field discarded integer Сколько закрыто и забыто
---@field open_failures integer Сколько раз открыть не удалось
---@field takes integer Сколько раз соединение выдавалось
---@field gives integer Сколько раз возвращалось
---@field drops integer Сколько раз его выбрасывали как негодное
---@field waits integer Сколько раз пришлось встать в очередь
---@field wait_timeouts integer Сколько ожиданий кончилось ничем
---@field leaks integer Сколько удержаний признано утёкшими

---@class TntPool
---@field settings TntPoolSettings Проверенные настройки
---@field entries table<any, TntPoolEntry> Соединение → его учётная запись
---@field idle TntPoolEntry[] Свободные; берётся с конца, чтобы лишние простаивали
---@field busy integer Сколько занято прямо сейчас
---@field total integer Сколько открыто и открывается прямо сейчас
---@field queue TntPoolWaiters Очередь ждущих
---@field closed boolean Закрыт ли пул
---@field counters TntPoolCounters Счётчики за всё время жизни пула
---@field opening TntPoolOpening Отказы открытия: пауза, приговор, текст последнего
---@field janitor any Такт уборки; `any` — цикл живёт в соседнем пакете
local Pool = {}
Pool.__index = Pool

--- Метод пула как отдельная функция.
---
--- Такт уборки хочет функцию без имени и без хозяина, а уборка — метод.
--- Замыкание для такого перехода пишется в каждом месте одинаково
--- и одинаково же остаётся непроверенным: зовут его не из проверки,
--- а изнутри чужого цикла.
---@param pool TntPool
---@param method string Имя метода
---@return fun(...): any
local function bound(pool, method)
    return function(...)
        return pool[method](pool, ...)
    end
end

--- Заводит пул.
---
--- Соединения не открываются заранее: пул, открывший восемь соединений
--- при старте узла, платит за них в тот миг, когда узел и так занят
--- подъёмом, — и платит зря, если до них так и не дойдёт дело.
---@param opts TntPoolOptions
---@return TntPool
function Module.new(opts)
    local settings = settings_of.check(opts)

    ---@type TntPool
    local self = setmetatable({
        settings = settings,
        entries = {},
        idle = {},
        busy = 0,
        total = 0,
        queue = waiters.new(function()
            return source().cond()
        end),
        closed = false,
        counters = {
            opened = 0,
            discarded = 0,
            open_failures = 0,
            takes = 0,
            gives = 0,
            drops = 0,
            waits = 0,
            wait_timeouts = 0,
            leaks = 0,
        },
        opening = opening_of.new(settings.open_cooldown),
        janitor = nil,
    }, Pool)

    if settings.sweep_interval > 0 then
        -- Уборка идёт своим тактом, а не только при обращениях: пул,
        -- который убирает простаивающие лишь тогда, когда у него что-то
        -- просят, в тихий час не убирает ничего — а тихий час и есть
        -- то время, ради которого заведён idle_timeout.
        --
        -- Такт меряется настоящими часами, а не подменёнными: подменённые
        -- прыгают на час вперёд по воле проверки, и цикл, считающий по ним
        -- паузу, получил бы ноль и закрутился бы вхолостую.
        self.janitor = loop.new({
            name = 'pool_' .. settings.name,
            interval = settings.sweep_interval,
            tick = bound(self, 'sweep'),
            on_error = bound(self, '_sweep_failed'),
        })

        self.janitor:start()
    end

    return self
end

--- Исчерпало ли соединение свой срок.
---
--- Оба срока считаются от разных мигов, и путать их нельзя: простой —
--- от возвращения в пул, время жизни — от открытия. Соединение, которое
--- берут раз в секунду, не простаивает никогда, но стареть не перестаёт.
---@param entry TntPoolEntry
---@param now number
---@return boolean
function Pool:_expired(entry, now)
    local settings = self.settings

    if settings.idle_timeout > 0 and now - entry.idle_since >= settings.idle_timeout then
        return true
    end

    return settings.max_lifetime > 0 and now - entry.created >= settings.max_lifetime
end

--- Годно ли соединение к выдаче.
---
--- Живость проверяется перед каждой выдачей, а не раз в такт уборки:
--- соединение, которое клиент уже пометил негодным, выданное взявшему,
--- стоило бы ему запроса. Плата за это — проверка обязана быть дешёвой
--- и обходиться без сети. Срока у неё нет: сетевой ping к молчащему
--- серверу не дал бы `take` уйти в свой срок, а к живому удвоил бы
--- обращения. Соединение, умершее молча, — сервер перезапустили,
--- межсетевой экран разорвал простаивающее, — местная проверка не видит:
--- его обнаружит первый запрос.
---@param entry TntPoolEntry
---@param now number
---@return boolean
function Pool:_usable(entry, now)
    local expired = self:_expired(entry, now)

    -- Без проверки живости годность — это ровно «не истекло».
    if expired or self.settings.alive == nil then
        return not expired
    end

    local ok, alive = pcall(self.settings.alive, entry.conn)

    return ok and alive == true
end

--- Закрывает соединение и забывает о нём.
---
--- Освободившееся место — повод разбудить первого в очереди: он ждёт
--- не именно это соединение, он ждёт возможности открыть своё.
---@param entry TntPoolEntry
function Pool:_discard(entry)
    self.entries[entry.conn] = nil
    self.total = self.total - 1
    self.counters.discarded = self.counters.discarded + 1

    if self.settings.close ~= nil then
        local ok, err = pcall(self.settings.close, entry.conn)

        if not ok then
            -- Отказ закрытия ничего не меняет для пула: соединение уже
            -- забыто. Но молчать о нём нельзя — это единственный след
            -- того, что на той стороне остался незакрытый сеанс.
            log.warn('закрыть соединение не удалось', {
                pool = self.settings.name,
                err = tostring(err),
            })
        end
    end

    self.queue:wake_one()
end

--- Отдаёт соединение взявшему.
---@param entry TntPoolEntry
---@param now number
---@return any conn
function Pool:_hand_out(entry, now)
    entry.busy = true
    entry.taken_at = now
    entry.reported = false
    entry.uses = entry.uses + 1

    self.busy = self.busy + 1
    self.counters.takes = self.counters.takes + 1

    return entry.conn
end

--- Берёт годное из свободных.
---
--- Берётся последнее положенное, а не первое: так работает малая часть
--- пула, а лишние соединения простаивают и уходят по idle_timeout. Брать
--- по кругу значило бы держать все восемь вечно горячими даже там, где
--- хватает двух.
---@param now number
---@return any|nil conn
function Pool:_reuse(now)
    while true do
        local entry = table.remove(self.idle)

        if entry == nil then
            return nil
        end

        if self:_usable(entry, now) then
            return self:_hand_out(entry, now)
        end

        self:_discard(entry)
    end
end

--- Можно ли прямо сейчас открывать новое соединение.
---@param now number
---@return boolean
function Pool:_may_open(now)
    return self.total < self.settings.size and self.opening:allows(now)
end

--- Открывает новое соединение.
---
--- Место занимается до открытия, а не после: `open` уходит в сеть и отдаёт
--- управление, и без брони десяток ждущих файберов, увидев одно свободное
--- место, открыл бы десяток соединений на пул размером в одно.
---@param now number
---@param left number Сколько осталось от срока взявшего; больше нуля
---@return any|nil conn
function Pool:_open(now, left)
    self.total = self.total + 1

    local ok, conn, err = pcall(self.settings.open, left)

    if not ok then
        conn, err = nil, conn
    end

    if conn ~= nil and self.entries[conn] ~= nil then
        -- Пул различает соединения по самому значению: одно и то же,
        -- отданное дважды, он посчитал бы одним, и второй взявший работал
        -- бы по чужому соединению, а счёт занятых уехал бы. Это отказ
        -- открытия наравне с сетевым: пауза после него нужна тем более,
        -- потому что повторный вызов вернёт то же самое.
        conn, err = nil, 'open вернул соединение, которое уже в пуле'
    end

    if conn == nil then
        local opening = self.opening

        self.total = self.total - 1
        self.counters.open_failures = self.counters.open_failures + 1
        opening:failed(err, source().monotonic())

        log.warn('соединение не открылось', {
            pool = self.settings.name,
            err = opening.last_error,
            streak = opening.streak,
        })

        -- Освободилось место, и первый в очереди ждёт именно его: он встал
        -- туда, когда места не было, и спит до своего срока, а не до конца
        -- паузы. Не разбуженный, он не попробовал бы открыть сам и не узнал
        -- бы, что ждать больше нечего. Если первый — сам открывавший,
        -- побудка пропадёт: он не спит и всё перепроверит сам.
        self.queue:wake_one()

        return nil
    end

    self.opening:succeeded()
    self.counters.opened = self.counters.opened + 1

    -- Запись заводится неполной, и через промежуточный `any` именно
    -- поэтому: соединение уходит взявшему тем же вызовом, и занятость,
    -- миг выдачи и след об утечке проставляет уже выдача. Проставить их
    -- здесь значило бы завести два места, где это делается, и однажды
    -- поправить только одно.
    ---@type any
    local entry = {
        conn = conn,
        created = now,
        uses = 0,
    }

    self.entries[conn] = entry

    return self:_hand_out(entry, now)
end

--- Достаёт соединение, если его можно достать прямо сейчас.
---
--- Свободные осматриваются дважды не по невнимательности. `open` уходит
--- в сеть и отдаёт управление, и за это время соседний файбер мог вернуть
--- своё соединение и послать побудку — а послать её было некому: ждущий
--- в этот миг не спал, а сидел внутри `open`. Потерянная побудка стоила бы
--- целого срока ожидания при свободном соединении в пуле.
---
--- Остаток срока для `open` считается заново, а не от `now`: осмотр
--- свободных зовёт чужие живость и закрытие, те вправе отдать управление,
--- и остаток от прежней отметки продлил бы `take` на их время. Считается
--- он по настоящим часам, как и весь срок пула, — это отступление от
--- правила `tnt-clock`, и безвредное. Ожидание внутри `open`, отсчитанное
--- от отметки цикла, кончится раньше срока на работу без уступки, но
--- не позже его, а `take` сам раньше срока не уходит. Зато остаток
--- никогда не больше срока `take`, и `open` обходится с ним как с любым
--- сроком вызова: `clock.monotonic() + left` — это миг самого пула.
---@param now number
---@param deadline number Срок взявшего по монотонным часам
---@return any|nil conn
function Pool:_try(now, deadline)
    local conn = self:_reuse(now)

    if conn ~= nil then
        return conn
    end

    local left = deadline - source().monotonic()

    -- Срок вышел — открывать некогда. Нуля `open` не получает: у многих
    -- клиентов срок в ноль значит «ждать без срока», а не «не ждать».
    if left <= 0 or not self:_may_open(now) then
        return nil
    end

    local opened = self:_open(now, left)

    if opened ~= nil then
        return opened
    end

    return self:_reuse(now)
end

--- Чем объяснить истёкший срок ожидания.
---
--- Отказ службы и нехватка соединений выглядят для взявшего одинаково —
--- «не дали», — а лечатся по-разному: первое чинят на той стороне, второе
--- решается размером пула. Поэтому причина называется. Место в пуле есть,
--- а соединения нет — значит, дело не в размере.
---@param span number Сколько ждали
---@return string
function Pool:_timeout_reason(span)
    local last_error = self.opening.last_error

    if self.total < self.settings.size and last_error ~= nil then
        return ('соединение не получено за %s с: %s'):format(span, last_error)
    end

    return ('соединение не получено за %s с: все %d заняты'):format(
        span,
        self.settings.size
    )
end

--- Закрыт ли пул.
---
--- Спрашивается вопросом, а не читается полем: ответ меняется, пока взявший
--- спит в очереди, — закрыть пул может соседний файбер, — и значение,
--- прочитанное до сна, после сна не стоит ничего.
---@return boolean
function Pool:is_closed()
    return self.closed
end

--- Берёт соединение из пула.
---
--- Взявший обязан вернуть его `give` или выбросить `drop`. Тот, кто
--- не хочет об этом помнить, берёт `with`.
---
--- Отказ — строка, кроме одного случая: окончательный отказ `open`
--- отдаётся тем самым значением, которое она вернула, — тот, кто его
--- собрал, знает о нём больше, чем пул уместил бы в строку.
---@param timeout number|nil Сколько ждать; по умолчанию wait_timeout
---@return any|nil conn
---@return any err Строка либо окончательный отказ `open` как есть
function Pool:take(timeout)
    if self:is_closed() then
        return nil, 'пул закрыт'
    end

    local span = settings_of.wait_of(timeout, self.settings.wait_timeout)

    -- Срок служит двум делам сразу, и база у него — настоящие часы, а не
    -- время планировщика. Первое дело — решить, истёк ли срок: это
    -- длительность от вызова, а по времени планировщика она считалась бы
    -- от последней уступки вызывающего, и его работа без уступки перед
    -- вызовом съела бы часть срока. Второе — остаток уходит в ожидание
    -- на условной переменной, а оно отсчитывает его от отметки цикла
    -- событий и после работы без уступки кончается раньше на её время.
    -- Это безвредно: срок перепроверяется после каждого пробуждения,
    -- недоспанное доспится следующим оборотом, и отказа по сроку раньше
    -- срока не бывает.
    local deadline = source().monotonic() + span

    ---@type TntPoolTicket|nil
    local ticket = nil

    while true do
        ---@type any
        local conn = nil

        -- Соединение достаётся первому в очереди. Пришедший, пока очередь
        -- не пуста, встаёт в её хвост, даже если свободное соединение есть
        -- прямо сейчас: иначе очередь перестаёт быть очередью, и дольше
        -- всех ждущий ждёт дольше всех.
        if self.queue:empty() or self.queue:is_head(ticket) then
            conn = self:_try(source().monotonic(), deadline)
        end

        if conn ~= nil then
            self.queue:remove(ticket)

            return conn
        end

        -- После окончательного отказа ждать есть чего, только пока в пуле
        -- есть хоть одно соединение: занятое вернут, открываемое откроют.
        -- Пустому пулу ждать нечего — своё открывать бессмысленно, — и
        -- взявший уходит сразу, а не через срок. Уходит и тот, кто в
        -- очереди не первый: первый уйдёт с тем же.
        if self.opening.final ~= nil and self.total == 0 then
            self.queue:remove(ticket)

            return nil, self.opening.final
        end

        -- Время читается после попытки, а не до неё: открытие уходит
        -- в сеть на свой срок, и отметка, снятая до него, отстала бы
        -- на всё его время — ожидание проспало бы и паузу после отказа,
        -- и сам срок ровно на столько.
        local now = source().monotonic()

        if deadline - now <= 0 then
            self.queue:remove(ticket)
            self.counters.wait_timeouts = self.counters.wait_timeouts + 1

            return nil, self:_timeout_reason(span)
        end

        if ticket == nil then
            ticket = self.queue:push()
            self.counters.waits = self.counters.waits + 1
        end

        -- Готовность судится по отметке после попытки, а не по той, с которой
        -- попытка шла: пауза могла выйти между ними, и первый в очереди,
        -- который открыл бы уже сейчас, проспал бы её конец до своего срока.
        local ready = self.queue:is_head(ticket) and self:_may_open(now)
        local _, broken = waiters.wait_on(ticket, self.opening:sleep_span(now, deadline, ready))

        if broken ~= nil then
            self.queue:remove(ticket)

            return nil, ('ожидание соединения прервано: %s'):format(broken)
        end

        if self:is_closed() then
            self.queue:remove(ticket)

            return nil, 'пул закрыт'
        end
    end
end

--- Сбрасывает состояние возвращённого соединения.
---
--- Годным считается только явное `true`: сброс, который упал или ответил
--- чем-то другим, ничего не обещал, а соединение без сброса помнит чужую
--- транзакцию, чужие временные таблицы, чужой выбранный раздел —
--- следующему взявшему всё это досталось бы молча.
---@param entry TntPoolEntry
---@return boolean scrubbed
function Pool:_scrub(entry)
    local reset = self.settings.reset

    if reset == nil then
        return true
    end

    local ok, scrubbed = pcall(reset, entry.conn)

    return ok and scrubbed == true
end

--- Возвращает соединение в пул.
---
--- Соединение, которое не удалось сбросить, и соединение, вернувшееся
--- в закрытый пул, не ложатся в свободные, а закрываются. Для взявшего
--- это всё равно возврат: соединение он отдал, и что пул с ним сделал —
--- забота пула.
---@param conn any
---@return boolean ok
---@return string|nil err
function Pool:give(conn)
    local entry = self.entries[conn]

    if entry == nil then
        return false, 'соединение не из этого пула'
    end

    if not entry.busy then
        -- Возврат дважды опаснее невозврата: одно и то же соединение
        -- оказалось бы в пуле двумя записями и досталось бы двум файберам
        -- сразу, а это перепутанные ответы, а не просто нехватка мест.
        return false, 'соединение уже возвращено'
    end

    entry.busy = false
    self.busy = self.busy - 1
    self.counters.gives = self.counters.gives + 1

    -- Закрытому пулу сброс ни к чему: соединение всё равно закроется,
    -- а сброс — это, возможно, поход в сеть.
    local scrubbed = not self:is_closed() and self:_scrub(entry)

    -- Сброс — чужой код и вправе отдать управление, поэтому всё, что было
    -- верно до него, после него перепроверяется. Соседний файбер мог
    -- выбросить соединение: оно уже закрыто и забыто. Положенное
    -- в свободные, оно досталось бы следующему взявшему закрытым, а
    -- закрытое второй раз увело бы счёт открытых ниже нуля.
    if self.entries[conn] ~= entry then
        return true
    end

    -- Мог и закрыть пул. Закрытие уже обошло свободные, уборка
    -- остановлена, и соединение, положенное в свободные теперь, не закрыл
    -- бы никто: сеанс на той стороне жил бы до перезапуска узла.
    if not scrubbed or self:is_closed() then
        self:_discard(entry)

        return true
    end

    entry.idle_since = source().monotonic()
    table.insert(self.idle, entry)
    self.queue:wake_one()

    return true
end

--- Убирает соединение из свободных, если оно там лежит.
---@param entry TntPoolEntry
function Pool:_forget_idle(entry)
    for index, waiting in ipairs(self.idle) do
        if waiting == entry then
            table.remove(self.idle, index)

            return
        end
    end
end

--- Выбрасывает негодное соединение.
---
--- Взявший знает о соединении то, чего не знает пул: что ответ не разобрался,
--- что транзакция осталась открытой, что сервер сказал «я перезагружаюсь».
--- Проверка живости этого не покажет — соединение отвечает на ping и после
--- любого из этих случаев.
---@param conn any
---@return boolean ok
---@return string|nil err
function Pool:drop(conn)
    local entry = self.entries[conn]

    if entry == nil then
        return false, 'соединение не из этого пула'
    end

    if entry.busy then
        self.busy = self.busy - 1
    else
        self:_forget_idle(entry)
    end

    self.counters.drops = self.counters.drops + 1
    self:_discard(entry)

    return true
end

--- Берёт соединение, делает дело и возвращает его в любом исходе.
---
--- Ошибка внутри тела не поднимается выше: прикладной код не должен падать
--- из-за чужого сервера. Но и соединение, на котором она случилась, в пул
--- не возвращается — пул не умеет отличить оборванную сеть от незакрытой
--- транзакции, а вторая досталась бы следующему взявшему вместе
--- с соединением.
---
--- Отказ тела — `nil, err` — поломкой не считается, и соединение уходит
--- обратно через `give`: «нет такой записи» не повод платить за новое
--- соединение. Но отказать тело могло и посреди своей транзакции, и тогда
--- следующий взявший получит её вместе с соединением и зафиксирует чужую
--- работу. Транзакций пул не видит, и отсекает такое соединение только
--- `reset`: кто открывает транзакции, задаёт его и отвечает в нём не `true`,
--- пока транзакция открыта. Отвечает без сети — у крюка нет срока, и `give`
--- на молчащем сервере не вернулся бы; откатить — дело тела до его отказа.
---@param fn fun(conn: any): any Что сделать с соединением
---@param timeout number|nil Сколько ждать соединения
---@return any result Что вернуло тело; nil, если взять не вышло или тело упало
---@return any err Отказ `take` как есть, отказ тела либо текст его ошибки
function Pool:with(fn, timeout)
    local conn, err = self:take(timeout)

    if conn == nil then
        return nil, err
    end

    --- Возвращает соединение и пропускает наружу всё, что вернуло тело.
    ---
    --- Через замыкание, а не через таблицу результатов: тело вправе вернуть
    --- и `nil, 'причина'`, а такую пару таблица не отличит от «не вернуло
    --- ничего».
    ---@param ok boolean
    ---@return any
    ---@return string|nil
    local function finish(ok, ...)
        if ok then
            self:give(conn)

            return ...
        end

        self:drop(conn)

        local failure = tostring((...))

        log.warn('работа с соединением сорвалась', {
            pool = self.settings.name,
            err = failure,
        })

        return nil, failure
    end

    return finish(pcall(fn, conn))
end

--- Кричит о тех, кто держит соединение дольше положенного.
---
--- Взявший и не вернувший не виден никак: пул считает соединение занятым,
--- запросов оно не делает, и заметить это можно только по тому, что через
--- сутки пул перестал выдавать что-либо. Отнимать соединение силой нельзя —
--- его, возможно, и правда используют, — поэтому найденное только называется.
---@param now number
function Pool:_report_leaks(now)
    local overdue = self.settings.leak_timeout

    if overdue > 0 then
        for _, entry in pairs(self.entries) do
            local held = now - entry.taken_at

            if entry.busy and not entry.reported and held >= overdue then
                entry.reported = true
                self.counters.leaks = self.counters.leaks + 1

                log.warn('соединение держат дольше срока: похоже на утечку', {
                    pool = self.settings.name,
                    held = held,
                    uses = entry.uses,
                })
            end
        end
    end
end

--- Говорит, что уборка сорвалась.
---
--- Такт уборки переживает собственную ошибку: мёртвый фибер не сообщает
--- о себе ничем, и пул, переставший убирать, выглядит точно так же, как
--- пул, которому нечего убирать.
---@param err any
function Pool:_sweep_failed(err)
    log.warn('уборка пула не удалась', { pool = self.settings.name, err = tostring(err) })
end

--- Убирает простаивающие и состарившиеся соединения.
---
--- Зовётся тактом уборки сам, но открыт наружу: проверке нужен разбор без
--- ожидания такта, а прикладному коду — возможность убрать по своему поводу,
--- например перед снятием нагрузки.
---@return integer closed Сколько соединений закрыто
function Pool:sweep()
    local now = source().monotonic()
    local pending = self.idle
    local closed = 0

    -- Список свободных отбирается целиком и сразу: закрытие соединения
    -- уходит в сеть и отдаёт управление, и возвращённое в это время чужое
    -- соединение легло бы в список, который уборка потом перезаписала бы
    -- своим, — то есть пропало бы вместе со счётом занятых.
    self.idle = {}

    for _, entry in ipairs(pending) do
        -- Соединение могли выбросить, пока уборка ходила закрывать соседа.
        -- Вернуть такое в свободные значит выдать следующему взявшему уже
        -- закрытое.
        if self.entries[entry.conn] ~= nil then
            -- Могли и закрыть пул: остановка такта не ждёт, пока он
            -- доработает, а закрытие обходит свободные, из которых уборка
            -- всё уже отобрала. Положенное обратно не закрыл бы никто.
            if self:is_closed() or self:_expired(entry, now) then
                self:_discard(entry)
                closed = closed + 1
            else
                table.insert(self.idle, entry)
            end
        end
    end

    self:_report_leaks(now)

    return closed
end

--- Закрывает пул.
---
--- Занятые соединения не отнимаются: файбер, работающий по соединению,
--- получил бы обрыв посреди запроса, а пул всё равно не знает, можно ли
--- этот запрос повторить. Они закроются, когда их вернут.
---
--- Так же закроются и те, что в этот миг ни заняты, ни свободны: одно
--- сбрасывает `give`, другие перебирает уборка. Обе отдают управление
--- чужому коду и после него перепроверяют закрытие сами.
---@return boolean ok
---@return string|nil err
function Pool:close()
    if self.closed then
        return false, 'пул уже закрыт'
    end

    self.closed = true

    if self.janitor ~= nil then
        self.janitor:stop()
    end

    local pending = self.idle

    self.idle = {}

    for index = #pending, 1, -1 do
        self:_discard(pending[index])
    end

    -- Ждущие будятся все сразу: ждать им больше нечего, и каждый уйдёт
    -- со своим отказом сам.
    self.queue:wake_all()

    return true
end

--- Что с пулом происходит.
---
--- Показатели двух родов, и оба нужны. Мгновенные (занято, свободно, ждут)
--- отвечают на вопрос «хватает ли», накопленные (открыто за всё время,
--- отказов открытия, ожиданий, истёкших сроков) — на вопрос «что тут было,
--- пока никто не смотрел». Пул, у которого всё время ноль занятых, но тысяча
--- переоткрытий, выглядит здоровым только по первым.
---
--- Паролей здесь нет: пул их не видит вовсе — вход заперт внутри `open`.
--- Единственное, что приходит снаружи, — текст отказа открытия; он попадает
--- и сюда, и в журнал, поэтому строку с паролем из `open` возвращать не стоит.
---@return table
function Pool:stats()
    local counters = self.counters

    return {
        name = self.settings.name,
        size = self.settings.size,
        busy = self.busy,
        idle = #self.idle,
        waiting = self.queue:count(),
        total = self.total,
        closed = self.closed,
        opened = counters.opened,
        discarded = counters.discarded,
        open_failures = counters.open_failures,
        last_open_error = self.opening.last_error,
        takes = counters.takes,
        gives = counters.gives,
        drops = counters.drops,
        waits = counters.waits,
        wait_timeouts = counters.wait_timeouts,
        leaks = counters.leaks,
    }
end

--- Настройки общего пула, проверенные при `configure`.
---@type TntPoolSettings|nil
local blueprint

--- Общий пул процесса. Ленив: заводится при первом обращении.
---@type TntPool|nil
local shared

--- Настраивает общий пул процесса.
---
--- Пул на процесс — это про одну службу, а не про все сразу: у postgres
--- и у redis свои `open` и свои размеры, и жить им положено в двух разных
--- пулах, заведённых через `new`. Синглтон здесь для приложения, у которого
--- служба одна, и для контейнера зависимостей, которому надо откуда-то взять
--- «тот самый» пул.
---
--- Прежний общий пул закрывается тут же: оставить его значило бы потерять
--- его соединения — ссылок на него больше нет, а сеансы на той стороне живы.
---@param opts TntPoolOptions
function Module.configure(opts)
    blueprint = settings_of.check(opts)

    if shared ~= nil then
        shared:close()
        shared = nil
    end
end

--- Общий пул процесса.
---
--- Ленив: заводится при первом обращении, а не при `configure`. Настройка
--- идёт при подъёме узла, когда ходить к чужой службе рано, да и незачем —
--- до неё может так и не дойти дело.
---@return TntPool
function Module.default()
    if shared == nil then
        if blueprint == nil then
            error('пул не настроен: позовите pool.configure до pool.default')
        end

        shared = Module.new(blueprint)
    end

    return shared
end

--- Забывает общий пул. Нужен проверкам и остановке узла.
function Module.reset()
    if shared ~= nil then
        shared:close()
        shared = nil
    end

    blueprint = nil
end

--- Что с общим пулом.
---
--- Отвечает и до того, как пул заведён: «настроен, но ещё не понадобился» —
--- нормальное состояние ленивого синглтона, а не отсутствие ответа.
---@return table
function Module.status()
    if shared == nil then
        return { configured = blueprint ~= nil, created = false }
    end

    local shown = shared:stats()

    shown.configured = true
    shown.created = true

    return shown
end

return Module
