--- Тесты одновременности: несколько файберов берут и возвращают разом.
---
--- Здесь ни часы, ни условная переменная не подменяются. Проверяется
--- именно то, что делает планировщик, а подменённое ожидание проходит мимо
--- него целиком: с ним очередь выглядит правильной, даже когда соединение
--- достаётся двоим сразу. Поэтому сроки здесь короткие и настоящие.

local clock = require('clock')
local fiber = require('fiber')
local t = require('luatest')

local g = t.group('tnt.pool.concurrency')

local helper = dofile('test/helper.lua')

---@type any
local service

--- Сколько ждать соединения в этих проверках.
---
--- Четверть секунды: время здесь настоящее, и срок, взятый с запасом,
--- платится целиком каждый раз, когда пул сломан. Файберам тут нечего
--- делать, кроме как уступить управление, и четверти секунды им хватает
--- с избытком.
local WAIT = 0.25

--- Сколько ждать ответа файбера, прежде чем счесть, что он не ответит.
---
--- Файберы здесь отвечают за доли секунды, и срок сбора ничего
--- не меряет: он только не даёт поломке повесить прогон. Поэтому он
--- с запасом. В полном прогоне с покрытием цикл событий останавливается
--- дольше секунды, и ответ, которому после остановки нужен ещё один оборот
--- цикла, опаздывал к секундному сроку сбора, хотя пул был прав.
local ANSWER = 3

--- Срок ждущего в проверках побудки.
---
--- Разбуженный пулом ждущий отвечает через доли секунды, неразбуженный —
--- только к концу своего срока, и отличить одного от другого можно лишь
--- по времени ответа. Граница между ними — половина срока: остановка цикла
--- под нагрузкой полного прогона короче её с запасом, а проспавший срок
--- переходит её наверняка. Срок сбора ответа такой меркой служить
--- не может: он отсчитывается от мига, когда проверка начала ждать,
--- а пауза после отказа — от самого отказа. Остановка цикла между ними
--- уводила конец паузы за срок сбора, и сбор кончался раньше, чем ждущий
--- успевал проснуться.
local ROUSED = 10

g.before_each(function()
    helper.load('tnt.pool')
    service = helper.service()
end)

g.after_each(function()
    helper.unload()
end)

--- Поднимает файбер и даёт ему дойти до ожидания.
---
--- Уступка управления нужна, чтобы очередь выстроилась в порядке запуска:
--- без неё файберы встают в неё в том порядке, в каком до них дошёл
--- планировщик, и проверка честности очереди проверяла бы планировщик.
---@param body fun()
local function spawn(body)
    fiber.create(body)
    fiber.sleep(0)
end

--- Забирает из канала названное число ответов.
---@param channel table
---@param count integer
---@param timeout number|nil Сколько ждать каждого; по умолчанию `ANSWER`
---@return table[]
local function collect(channel, count, timeout)
    local answers = {}

    for _ = 1, count do
        local answer = channel:get(timeout or ANSWER)

        t.assert_not_equals(answer, nil, 'файбер не ответил за отведённое время')
        table.insert(answers, answer)
    end

    return answers
end

--- Затвор: держит чужой код посреди вызова, пока проверка не пустит.
---
--- Крюки пула — чужой код, и уйти в сеть, отдав управление, им законно.
--- Сон на время здесь не годится: проверка не знала бы, дошёл ли файбер
--- до крюка, и гонка то случалась бы, то нет. Непущенный стоит не дольше
--- срока ожидания и уходит с отказом, поэтому упавшая проверка не
--- оставляет за собой висящего файбера.
---@return table
local function gate()
    local reached = fiber.channel(1)
    local opened = fiber.channel(1)

    return {
        --- Встаёт у затвора; `true` — пустили.
        pass = function()
            reached:put(true)

            return opened:get(WAIT) == true
        end,

        --- Ждёт, пока у затвора кто-нибудь встанет.
        reached = function()
            t.assert_equals(reached:get(WAIT), true, 'до затвора никто не дошёл')
        end,

        --- Пускает стоящего.
        open = function()
            opened:put(true)
        end,
    }
end

--- Зовёт метод пула в своём файбере и отдаёт канал с его ответом.
---
--- `fiber.create` исполняет новый файбер сразу, до первой уступки, поэтому
--- к возврату отсюда вызов уже стоит у затвора, если до него дошёл.
---@param p table Пул
---@param method string Имя метода
---@param ... any Аргументы метода
---@return table channel Канал, в который придёт список ответов
local function call_aside(p, method, ...)
    local answers = fiber.channel(1)
    local given = { ... }

    fiber.create(function()
        answers:put({ p[method](p, unpack(given)) })
    end)

    return answers
end

--- Что вернул вызов, отданный `call_aside`: список его ответов.
---@param channel table
---@return table
local function answer_of(channel)
    return collect(channel, 1)[1] --[[@as table]]
end

--- Что ответил ждущий, которого должен был разбудить пул.
---
--- Ответ ждётся дольше срока ждущего: проспавший тоже ответит, и проверка
--- назовёт его проспавшим, а не молчащим.
---@param channel table Канал ответа ждущего
---@param since number Миг по настоящим часам не позже его прихода в очередь
---@return table
local function roused(channel, since)
    local answer = collect(channel, 1, ROUSED + ANSWER)[1] --[[@as table]]

    t.assert_lt(
        clock.monotonic() - since,
        ROUSED / 2,
        'ждущий проспал свой срок: пул его не разбудил'
    )

    return answer
end

g.test_fibers_never_hold_the_same_connection_at_once = function()
    local p = helper.pool_of(service, { size = 3, wait_timeout = WAIT })
    local held = {}
    local clashes = 0
    local refusals = {}
    local done = fiber.channel(8)

    for _ = 1, 8 do
        fiber.create(function()
            for _ = 1, 5 do
                local answer, err = p:with(function(conn)
                    if held[conn] then
                        clashes = clashes + 1
                    end

                    held[conn] = true
                    fiber.sleep(0)
                    held[conn] = nil

                    return true
                end)

                if answer ~= true then
                    table.insert(refusals, tostring(err))
                end
            end

            done:put(true)
        end)
    end

    collect(done, 8)

    t.assert_equals(clashes, 0)
    t.assert_equals(refusals, {})

    local shown = p:stats()

    t.assert_equals(shown.takes, 40)
    t.assert_equals(shown.gives, 40)
    t.assert_equals(shown.busy, 0)
    t.assert_equals(shown.waiting, 0)
    t.assert_equals(shown.total, service.opened)
    t.assert_le(shown.total, 3)
    t.assert_equals(p:close(), true)
end

g.test_waiting_fibers_are_served_in_order_of_arrival = function()
    local p = helper.pool_of(service, { size = 1, wait_timeout = WAIT })
    local first = p:take()
    local order = {}
    local done = fiber.channel(3)

    for index = 1, 3 do
        spawn(function()
            local conn = p:take()

            -- В след пишется и номер файбера, и номер доставшегося
            -- соединения: очередь, которая выстроилась правильно, но никому
            -- ничего не дала, выглядела бы отсюда исправной.
            table.insert(order, ('%d:%s'):format(index, conn and conn.id or 'ничего'))
            p:give(conn)
            done:put(true)
        end)
    end

    t.assert_equals(p:stats().waiting, 3)
    p:give(first)
    collect(done, 3)

    -- Соединение достаётся первому в очереди, а не тому, кого планировщик
    -- поднял раньше: иначе дольше всех ждущий ждёт дольше всех.
    t.assert_equals(order, { '1:1', '2:1', '3:1' })
    t.assert_equals(service.opened, 1)
    t.assert_equals(p:stats().waits, 3)
    t.assert_equals(p:close(), true)
end

g.test_returned_connection_goes_to_the_one_who_waited = function()
    local p = helper.pool_of(service, { size = 1, wait_timeout = WAIT })
    local first = p:take()
    local taken = fiber.channel(1)

    spawn(function()
        taken:put(p:take())
    end)

    t.assert_equals(p:stats().waiting, 1)
    p:give(first)

    -- Побудка доходит с первой же уступкой управления. Ждущий, которого
    -- никто не разбудил, получит то же самое соединение — но не раньше,
    -- чем истечёт его срок, и на пуле под нагрузкой это разница между
    -- работой и её видимостью.
    fiber.sleep(0)

    t.assert_equals(p:stats().waiting, 0)

    local got = collect(taken, 1)[1]

    t.assert_equals(got, first)
    t.assert_equals(service.opened, 1)
    t.assert_equals(p:stats().busy, 1)
    t.assert_equals(p:give(got), true)
    t.assert_equals(p:close(), true)
end

g.test_closing_the_pool_wakes_everybody_who_waits = function()
    -- Закрытие происходит раньше, чем выйдет срок: ждущий, которого оно
    -- не разбудило, ушёл бы не с «пул закрыт», а с истёкшим сроком.
    local p = helper.pool_of(service, { size = 1, wait_timeout = WAIT })
    local held = p:take()
    local answers = fiber.channel(2)

    for _ = 1, 2 do
        spawn(function()
            local conn, err = p:take()

            answers:put({ conn = conn, err = err })
        end)
    end

    t.assert_equals(p:stats().waiting, 2)
    t.assert_equals(p:close(), true)

    for _, answer in ipairs(collect(answers, 2)) do
        t.assert_equals(answer.conn, nil)
        t.assert_equals(answer.err, 'пул закрыт')
    end

    t.assert_equals(p:give(held), true)
    t.assert_equals(p:stats().total, 0)
end

--- Возвращает соединение, пока его сброс стоит у затвора.
---
--- Пока сброс стоит, проверка делает с пулом своё: соединение в этот миг
--- ни занято, ни свободно, и именно здесь возврат обязан перепроверить
--- всё, что узнал до сброса.
---@param meanwhile fun(p: table, conn: any) Что сделать, пока идёт сброс
---@return table p Пул
---@return table|nil answer Что ответил `give`; пустоты `collect` не пропустит
local function give_while_scrubbing(meanwhile)
    local scrub = gate()
    local p = helper.pool_of(service, { reset = scrub.pass })
    local conn = p:take()
    local given = call_aside(p, 'give', conn)

    scrub.reached()
    meanwhile(p, conn)
    scrub.open()

    return p, collect(given, 1)[1]
end

g.test_connection_given_back_while_the_pool_was_closed_is_closed = function()
    -- Сброс отдал управление, а пул тем временем закрыли. Закрытие обошло
    -- свободные без этого соединения, уборка остановлена: положенное
    -- в свободные теперь не закрыл бы никто, и сеанс на той стороне жил бы
    -- до перезапуска узла.
    local p, answer = give_while_scrubbing(function(closing)
        t.assert_equals(closing:close(), true)
    end)

    t.assert_equals(answer, { true })
    t.assert_equals(service.closed, { 1 })

    local shown = p:stats()

    t.assert_equals(shown.idle, 0)
    t.assert_equals(shown.busy, 0)
    t.assert_equals(shown.total, 0)
    t.assert_equals(shown.discarded, 1)
end

g.test_connection_dropped_while_it_was_scrubbed_stays_forgotten = function()
    -- Выброшенное во время сброса уже закрыто и забыто. Возврат, положивший
    -- его в свободные, выдал бы следующему взявшему закрытое, а закрытие
    -- по второму разу увело бы счёт открытых ниже нуля.
    local p, answer = give_while_scrubbing(function(dropping, conn)
        t.assert_equals(dropping:drop(conn), true)
    end)

    t.assert_equals(answer, { true })
    t.assert_equals(service.closed, { 1 })

    local shown = p:stats()

    t.assert_equals(shown.idle, 0)
    t.assert_equals(shown.total, 0)
    t.assert_equals(shown.discarded, 1)
    t.assert_equals(shown.drops, 1)

    -- Пул после этого исправен: следующий взявший получает новое
    -- соединение, а не выброшенное.
    t.assert_equals(p:take(), { id = 2 })
    t.assert_equals(p:close(), true)
end

g.test_sweep_closes_the_rest_when_the_pool_was_closed_meanwhile = function()
    -- Уборка отобрала свободные и ушла закрывать простоявшее, а пул тем
    -- временем закрыли. Остановка такта уборку не ждёт, а закрытию обходить
    -- нечего: всё свободное у уборки. Соседнее, ещё не простоявшее своего,
    -- легло бы обратно в свободные закрытого пула, где его не закрыл бы уже
    -- никто.
    local real = require('clock')
    local idle = 0.1
    local shut = gate()

    local p = helper.pool_of(service, {
        idle_timeout = idle,
        close = function(conn)
            service.close(conn)

            if conn.id == 1 then
                shut.pass()
            end
        end,
    })

    local stale = p:take()
    local fresh = p:take()

    p:give(stale)

    -- Время здесь настоящее, и простой меряется по нему же. Сон отсчитывает
    -- срок от отметки цикла событий, а она отстаёт от настоящих часов на
    -- работу без уступки, поэтому ждётся не сон, а сам простой. Соседнее
    -- возвращается перед самой уборкой, и его срок от неё далёк.
    local given_at = real.monotonic()

    repeat
        fiber.sleep(idle / 2)
    until real.monotonic() - given_at > idle

    p:give(fresh)

    local swept = call_aside(p, 'sweep')

    shut.reached()
    t.assert_equals(p:close(), true)
    shut.open()

    t.assert_equals(collect(swept, 1)[1], { 2 })
    t.assert_equals(service.closed, { 1, 2 })

    local shown = p:stats()

    t.assert_equals(shown.idle, 0)
    t.assert_equals(shown.total, 0)
    t.assert_equals(shown.discarded, 2)
end

g.test_pool_never_opens_more_than_its_size_even_when_open_is_slow = function()
    service.slow = true

    local p = helper.pool_of(service, { size = 2, wait_timeout = WAIT })
    local done = fiber.channel(6)

    for _ = 1, 6 do
        fiber.create(function()
            local answer = p:with(function()
                fiber.sleep(0)

                return true
            end)

            done:put(answer == true)
        end)
    end

    for _, answer in ipairs(collect(done, 6)) do
        t.assert_equals(answer, true)
    end

    -- Место под открытие бронируется до похода в сеть: без брони шесть
    -- файберов, увидев два свободных места, открыли бы шесть соединений
    -- на пул размером в два.
    t.assert_le(service.opened, 2)
    t.assert_ge(service.opened, 1)
    t.assert_equals(p:stats().total, service.opened)
    t.assert_equals(p:stats().takes, 6)
    t.assert_equals(p:close(), true)
end

g.test_connection_returned_while_open_was_away_is_not_missed = function()
    -- Пока `open` ходит в сеть, соседний файбер возвращает своё соединение
    -- и посылает побудку — а ждущего в очереди ещё нет, и будить некого.
    -- Без повторного осмотра свободных он проспал бы весь свой срок рядом
    -- с готовым соединением.
    service.slow = true

    local p = helper.pool_of(service, { size = 2, wait_timeout = WAIT, open_cooldown = 30 })
    local held = p:take()
    local taken = fiber.channel(1)

    -- Следующее открытие откажет, а пауза после отказа длиннее срока
    -- ожидания: второй раз открыть он уже не попробует.
    service.failures = 1

    fiber.create(function()
        taken:put(p:take())
    end)

    t.assert_equals(p:stats().waiting, 0)
    t.assert_equals(p:give(held), true)

    local got = collect(taken, 1)[1]

    t.assert_equals(got, held)
    t.assert_equals(service.attempts, 2)
    t.assert_equals(service.opened, 1)
    t.assert_equals(p:stats().open_failures, 1)
    t.assert_equals(p:stats().waits, 0)
    t.assert_equals(p:give(got), true)
    t.assert_equals(p:close(), true)
end

--- Пул на одно место, чей первый вход стоит у затвора, и ждущий за ним.
---
--- Второй взявший встаёт в очередь, пока место занято входом первого, и
--- засыпает на весь свой срок: паузы после отказа ещё нет. Вход после
--- этого отказывает — и узнать об освободившемся месте ждущему не от кого,
--- кроме самого пула.
---@param opts table Что поменять в настройках пула
---@return table p Пул
---@return table first Канал ответа того, кто входил
---@return table second Канал ответа ждущего
local function queued_behind_a_refused_login(opts)
    local login = gate()
    local refuse = service.open

    local settings = {
        size = 1,
        open = function(left)
            if service.attempts == 0 then
                login.pass()
            end

            return refuse(left)
        end,
    }

    for key, value in pairs(opts) do
        settings[key] = value
    end

    local p = helper.pool_of(service, settings)
    local first = call_aside(p, 'take')

    login.reached()

    local second = call_aside(p, 'take')

    t.assert_equals(p:stats().waiting, 1)
    login.open()

    return p, first, second
end

g.test_waiter_hears_a_final_refusal_at_once = function()
    -- Срок длинный нарочно: неразбуженный ждущий ответил бы только к его
    -- концу, и время ответа это выдаст.
    local denied = { retriable = false, message = 'пароль неверен' }

    service.failures = math.huge
    service.reason = denied

    local queued = clock.monotonic()
    local p, first, second = queued_behind_a_refused_login({ wait_timeout = ROUSED })

    t.assert_is(answer_of(first)[2], denied)
    t.assert_is(roused(second, queued)[2], denied)
    t.assert_equals(service.attempts, 1)
    t.assert_equals(p:stats().waiting, 0)
    t.assert_equals(p:close(), true)
end

g.test_waiter_tries_to_open_once_the_pause_after_a_refusal_is_over = function()
    -- Отказ временный: ждущий, не разбуженный им, проспал бы весь срок,
    -- хотя после короткой паузы вход удался бы. Время его ответа это
    -- и выдаст.
    service.failures = 1

    local queued = clock.monotonic()
    local p, first, second = queued_behind_a_refused_login({ wait_timeout = ROUSED, open_cooldown = 0.01 })
    local waiter = roused(second, queued)

    t.assert_equals(waiter[1], { id = 1 })
    t.assert_equals(service.attempts, 2)
    t.assert_equals(p:give(waiter[1]), true)

    -- Тот, чей вход не удался, стоит в очереди за ждущим и получает то же
    -- соединение после него.
    t.assert_equals(answer_of(first)[1], { id = 1 })
    t.assert_equals(p:close(), true)
end

g.test_work_without_yielding_before_the_call_does_not_eat_the_deadline = function()
    -- Срок меряется от вызова настоящими часами. Ожидание отсчитывает
    -- остаток от отметки цикла событий, застывшей на время работы без
    -- уступки, и просыпается раньше; пул перепроверяет срок и досыпает
    -- остаток, а не уходит с отказом раньше срока.
    local real = require('clock')
    local p = helper.pool_of(service, { size = 1, wait_timeout = WAIT })
    local held = p:take()

    fiber.yield()

    local began = real.monotonic()
    local spins = 0

    repeat
        spins = spins + 1
    until real.monotonic() - began >= WAIT / 5

    local called = real.monotonic()
    local conn, err = p:take()

    t.assert_equals(conn, nil)
    t.assert_equals(err, 'соединение не получено за 0.25 с: все 1 заняты')
    t.assert_ge(real.monotonic() - called, WAIT)
    t.assert_equals(p:give(held), true)
    t.assert_equals(p:close(), true)
end
