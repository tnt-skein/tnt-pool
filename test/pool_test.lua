--- Тесты пула соединений: выдача, возврат, сроки и отказы.
---
--- Часы и условная переменная подменены: сроки проверяются целиком и точно,
--- а настоящего времени проверка не тратит. Одновременность здесь не
--- проверяется — для неё нужны настоящие файберы, и она живёт отдельно,
--- в concurrency_test.lua.

local fiber = require('fiber')
local t = require('luatest')

local g = t.group('tnt.pool')

--- Ошибки Tarantool: ими `open` тоже вправе отказать. Конструктор
--- в аннотациях описан не полностью, поэтому берётся через ссылку без типа.
---@type any
local box_error = box.error

local helper = dofile('test/helper.lua')

local journal = helper.capture_log()

--- Этот файл — так его называет место в сообщении об ошибке.
local THIS_FILE = assert(debug.getinfo(1, 'S'), 'нет отладочной информации').short_src

---@type any
local pool

---@type any
local service

--- Подменённые часы: их двигает только проверка.
---@type TntTestingClock
local clock

g.before_each(function()
    pool = helper.load('tnt.pool')

    local source

    clock, source = helper.clock()

    pool._set_source(source)
    service = helper.service()
    journal.forget()
end)

g.after_each(function()
    pool.reset()
    pool._set_source(nil)
    helper.unload()
end)

g.after_all(function()
    journal.release()
end)

g.test_first_take_opens_a_connection = function()
    local p = helper.pool_of(service)

    t.assert_equals(p:take(), { id = 1 })
    t.assert_equals(service.attempts, 1)

    local shown = p:stats()

    t.assert_equals(shown.busy, 1)
    t.assert_equals(shown.idle, 0)
    t.assert_equals(shown.total, 1)
    t.assert_equals(shown.opened, 1)
    t.assert_equals(shown.takes, 1)
    t.assert_equals(shown.waiting, 0)
end

g.test_returned_connection_is_handed_out_again = function()
    local p = helper.pool_of(service)
    local first = p:take()

    t.assert_equals(p:give(first), true)
    t.assert_equals(p:stats().idle, 1)
    t.assert_equals(p:stats().busy, 0)
    t.assert_equals(p:take(), first)
    t.assert_equals(service.opened, 1)
    t.assert_equals(p:stats().takes, 2)
    t.assert_equals(p:stats().gives, 1)
end

g.test_pool_opens_up_to_its_size_and_no_further = function()
    local p = helper.pool_of(service, { size = 2, wait_timeout = 5 })
    local first = p:take()
    local second = p:take()

    t.assert_not_equals(first, second)

    local third, err = p:take()

    t.assert_equals(third, nil)
    t.assert_equals(err, 'соединение не получено за 5 с: все 2 заняты')
    t.assert_equals(service.attempts, 2)

    -- Ждал ровно свой срок: ни на шаг раньше и ни на шаг дольше.
    t.assert_equals(clock.monotonic(), 1005)
    t.assert_equals(p:stats().waits, 1)
    t.assert_equals(p:stats().wait_timeouts, 1)
    t.assert_equals(p:stats().waiting, 0)
end

g.test_deadline_given_with_the_call_wins_over_the_setting = function()
    local p = helper.pool_of(service, { size = 1, wait_timeout = 5 })

    p:take()

    local conn, err = p:take(2)

    t.assert_equals(conn, nil)
    t.assert_equals(err, 'соединение не получено за 2 с: все 1 заняты')
    t.assert_equals(clock.monotonic(), 1002)
end

g.test_taking_without_a_deadline_is_refused = function()
    local p = helper.pool_of(service)
    local ok, err = pcall(p.take, p, 0)

    t.assert_equals(ok, false)
    t.assert_str_contains(
        tostring(err),
        'срок ожидания обязателен: без него ждут навсегда'
    )
end

g.test_dead_connection_is_replaced_before_it_is_handed_out = function()
    local p = helper.pool_of(service, { alive = service.alive })

    p:give(p:take())
    service.live = false

    t.assert_equals(p:take(), { id = 2 })
    t.assert_equals(service.closed, { 1 })
    t.assert_equals(p:stats().discarded, 1)
    t.assert_equals(p:stats().total, 1)
end

g.test_liveness_check_that_fell_counts_as_death = function()
    local p = helper.pool_of(service, {
        alive = function()
            error('ping не дошёл')
        end,
    })

    p:give(p:take())

    t.assert_equals(p:take(), { id = 2 })
    t.assert_equals(service.closed, { 1 })
end

g.test_idle_connection_is_closed_once_it_has_stood_too_long = function()
    local p = helper.pool_of(service, { idle_timeout = 10 })

    p:give(p:take())
    clock.advance(25)

    t.assert_equals(p:sweep(), 1)
    t.assert_equals(p:stats().idle, 0)
    t.assert_equals(p:stats().total, 0)
    t.assert_equals(p:stats().discarded, 1)
    t.assert_equals(service.closed, { 1 })
end

g.test_idle_connection_goes_the_moment_its_time_is_up = function()
    local p = helper.pool_of(service, { idle_timeout = 10 })

    p:give(p:take())
    clock.advance(10)

    t.assert_equals(p:sweep(), 1)
    t.assert_equals(service.closed, { 1 })
end

g.test_idle_connection_stands_until_its_time_is_up = function()
    local p = helper.pool_of(service, { idle_timeout = 10 })

    p:give(p:take())
    clock.advance(9.999)

    t.assert_equals(p:sweep(), 0)
    t.assert_equals(p:stats().idle, 1)
    t.assert_equals(service.closed, {})
end

g.test_zero_idle_timeout_keeps_connections_for_as_long_as_they_live = function()
    local p = helper.pool_of(service, { idle_timeout = 0, max_lifetime = 0 })

    p:give(p:take())
    clock.advance(100000)

    t.assert_equals(p:sweep(), 0)
    t.assert_equals(p:stats().idle, 1)
end

g.test_connection_retires_when_it_has_lived_long_enough = function()
    -- Простой здесь ни при чём: соединение берут и возвращают всё время,
    -- но стареть оно от этого не перестаёт.
    local p = helper.pool_of(service, { idle_timeout = 0, max_lifetime = 100 })
    local conn = p:take()

    clock.advance(99)
    p:give(conn)

    t.assert_equals(p:sweep(), 0)

    clock.advance(1)

    t.assert_equals(p:sweep(), 1)
    t.assert_equals(service.closed, { 1 })
end

g.test_short_lifetime_is_honoured_like_any_other = function()
    -- Секунда — законный срок жизни, а не «почти ноль»: за ним стоит предел
    -- чужой службы, и округлять его до «без предела» нельзя.
    local p = helper.pool_of(service, { idle_timeout = 0, max_lifetime = 1 })
    local conn = p:take()

    clock.advance(30)
    p:give(conn)

    t.assert_equals(p:sweep(), 1)
    t.assert_equals(service.closed, { 1 })
end

g.test_living_connection_is_handed_out_again = function()
    local p = helper.pool_of(service, { alive = service.alive })
    local first = p:take()

    p:give(first)

    t.assert_equals(p:take(), first)
    t.assert_equals(service.opened, 1)
    t.assert_equals(p:stats().discarded, 0)
end

g.test_expired_connection_is_not_handed_out_even_between_sweeps = function()
    local p = helper.pool_of(service, { idle_timeout = 10 })

    p:give(p:take())
    clock.advance(10)

    t.assert_equals(p:take(), { id = 2 })
    t.assert_equals(p:stats().discarded, 1)
    t.assert_equals(service.closed, { 1 })
end

g.test_pool_without_a_way_to_close_just_forgets_the_connection = function()
    local p = pool.new({ open = service.open, size = 1, idle_timeout = 1, sweep_interval = 0 })

    p:give(p:take())
    clock.advance(1)

    t.assert_equals(p:sweep(), 1)
    t.assert_equals(service.closed, {})
    t.assert_equals(p:stats().total, 0)
end

g.test_refusal_to_open_does_not_end_the_wait_at_once = function()
    service.failures = 1

    local p = helper.pool_of(service, { open_cooldown = 0.5, wait_timeout = 5 })

    t.assert_equals(p:take(), { id = 1 })
    t.assert_equals(service.attempts, 2)

    -- Ждал ровно паузу после отказа, а не весь свой срок.
    t.assert_equals(clock.monotonic(), 1000.5)
    t.assert_equals(p:stats().open_failures, 1)
    t.assert_str_contains(p:stats().last_open_error, 'служба не отвечает')
end

g.test_refusals_to_open_are_spaced_wider_every_time = function()
    service.failures = math.huge

    local p = helper.pool_of(service, { open_cooldown = 0.5, wait_timeout = 4.5 })
    local conn, err = p:take()

    t.assert_equals(conn, nil)
    t.assert_equals(
        err,
        'соединение не получено за 4.5 с: открыть соединение не удалось: служба не отвечает'
    )

    -- Паузы 0.5, 1, 2, 4: попытки в 0, 0.5, 1.5 и 3.5 секунды, а пятой
    -- уже не хватает срока. Без удвоения их было бы девять.
    t.assert_equals(service.attempts, 4)
    t.assert_equals(p:stats().open_failures, 4)

    -- Срок дожидается до конца: последняя пауза длиннее остатка, и взявший
    -- спит ровно остаток, а не уходит на секунду раньше.
    t.assert_equals(clock.monotonic(), 1004.5)
    t.assert_equals(journal.logged('соединение не открылось'), true)
end

--- Условная переменная, которую один раз будят на середине сна.
---
--- В очереди будят и тогда, когда соединения не прибавилось: соседнее
--- выбросили, соседний вход не удался. Двойник часов сам не будит никого,
--- и такую побудку изображает она: первое ожидание кончается на половине
--- срока, остальные досыпают его целиком. Побудки, посланные мимо сна,
--- пропадают, как у `fiber.cond`: в проверке с одним файбером спящих
--- в миг побудки нет.
---@return fun(): table
local function woken_halfway()
    local woken = false

    return function()
        return {
            wait = function(_, seconds)
                local span = woken and seconds or seconds / 2

                woken = true
                clock.advance(span)

                return false
            end,

            signal = function() end,

            broadcast = function() end,
        }
    end
end

g.test_refusal_without_a_pause_is_tried_again_on_the_next_wakeup = function()
    service.failures = math.huge
    pool._set_source({ monotonic = clock.monotonic, cond = woken_halfway() })

    local p = helper.pool_of(service, { open_cooldown = 0, wait_timeout = 1 })
    local conn, err = p:take()

    t.assert_equals(conn, nil)
    t.assert_str_contains(err, 'служба не отвечает')

    -- Пауза в ноль — это «не ждать открытия дольше нужного», а не «пробовать
    -- без передышки»: попытка повторяется на следующей побудке, иначе пул
    -- сжёг бы весь срок на подряд идущих попытках, не уступив управления.
    -- В сам срок попытки нет: открывать уже некогда.
    t.assert_equals(service.lefts, { 1, 0.5 })
    t.assert_equals(clock.monotonic(), 1001)
end

g.test_open_is_given_what_is_left_of_the_deadline = function()
    service.failures = 2

    local p = helper.pool_of(service, { open_cooldown = 0.5, wait_timeout = 5 })

    t.assert_equals(p:take(), { id = 1 })

    -- Попытки в 0, 0.5 и 1.5 секунды: каждой — остаток, а не весь срок.
    -- Первая получает ровно срок: больше `take` ей не отпускал.
    t.assert_equals(service.lefts, { 5, 4.5, 3.5 })

    p:take(2)

    t.assert_equals(service.lefts[4], 2)
end

g.test_login_to_a_silent_server_ends_with_the_deadline = function()
    -- У клиента своего срока входа нет, и вход ждёт столько, сколько ему
    -- дали. Без остатка аргументом вход к молчащему серверу длился бы, пока
    -- тот молчит, и `take` вернулся бы за своим сроком.
    local p = helper.pool_of(service, {
        wait_timeout = 3,
        open = function(left)
            service.attempts = service.attempts + 1
            clock.advance(left)

            return nil, 'вход не завершился за срок'
        end,
    })

    local conn, err = p:take()

    t.assert_equals(conn, nil)
    t.assert_equals(
        err,
        'соединение не получено за 3 с: открыть соединение не удалось: вход не завершился за срок'
    )
    t.assert_equals(service.attempts, 1)
    t.assert_equals(clock.monotonic(), 1003)
end

g.test_nothing_is_opened_once_the_scheduler_overshot_the_deadline = function()
    -- Планировщик разбудил позже срока: остаток отрицательный, и открывать
    -- с ним нечего.
    local late, source = helper.clock({ overshoot = 0.25 })

    pool._set_source(source)
    service.failures = math.huge

    local p = helper.pool_of(service, { open_cooldown = 0, wait_timeout = 1 })

    t.assert_equals(p:take(), nil)
    t.assert_equals(service.lefts, { 1 })
    t.assert_equals(late.monotonic(), 1001.25)
end

--- Отказ, про который служба говорит: повторять бессмысленно.
---
--- Таблица с `__tostring`: так её текст попадает в журнал и в `stats`,
--- а не адрес таблицы.
---@param message string
---@return table
local function final_refusal(message)
    return setmetatable({ kind = 'denied', message = message, retriable = false }, {
        __tostring = function(self)
            return self.message
        end,
    })
end

g.test_final_refusal_is_handed_over_at_once_and_as_it_is = function()
    local denied = final_refusal('пароль неверен')
    local p = helper.pool_of(service, { open_cooldown = 0.5, wait_timeout = 5 })

    service.failures = math.huge
    service.reason = denied

    local conn, err = p:take()

    t.assert_equals(conn, nil)
    t.assert_is(err, denied)

    -- Сразу — раньше, чем вышла бы пауза до второй попытки, не то что срок.
    t.assert_equals(clock.monotonic(), 1000)
    t.assert_equals(service.attempts, 1)

    local shown = p:stats()

    t.assert_equals(shown.open_failures, 1)
    t.assert_equals(
        shown.last_open_error,
        'открыть соединение не удалось: пароль неверен'
    )
    t.assert_equals(shown.waits, 0)
    t.assert_equals(shown.wait_timeouts, 0)
    t.assert_equals(shown.waiting, 0)
    t.assert_equals(shown.total, 0)
    t.assert_equals(journal.logged('соединение не открылось'), true)
end

g.test_final_refusal_reaches_the_caller_of_with = function()
    local denied = box_error.new({ reason = 'нет такой базы', retriable = false })

    service.failures = 1
    service.reason = denied

    local p = helper.pool_of(service)
    local answer, err = p:with(function()
        return 'до тела не дойдёт'
    end)

    t.assert_equals(answer, nil)
    t.assert_is(err, denied)
    t.assert_equals(tostring(err), 'нет такой базы')
    t.assert_equals(clock.monotonic(), 1000)
end

g.test_everyone_is_refused_at_once_while_the_pause_lasts = function()
    local denied = final_refusal('пароль неверен')
    local p = helper.pool_of(service, { open_cooldown = 0.5, wait_timeout = 5 })

    service.failures = 1
    service.reason = denied
    p:take()

    -- Пауза идёт, соединений нет — ждать второму нечего, и службу он
    -- не спрашивает: пароль, который пробуют сотней файберов, — сотня
    -- записей в её журнале безопасности.
    local conn, err = p:take()

    t.assert_equals(conn, nil)
    t.assert_is(err, denied)
    t.assert_equals(service.attempts, 1)
    t.assert_equals(clock.monotonic(), 1000)

    -- Пауза вышла — службу спрашивают снова: пароль могли и поправить.
    clock.advance(0.5)

    t.assert_equals(p:take(), { id = 1 })
    t.assert_equals(service.lefts, { 5, 5 })
end

g.test_pool_with_connections_waits_after_a_final_refusal = function()
    -- Соединение в пуле есть и может вернуться: ждут его, как в полном
    -- пуле, и по сроку называют отказ службы.
    local p = helper.pool_of(service, { open_cooldown = 0.5, wait_timeout = 1 })

    p:take()
    service.failures = math.huge
    service.reason = final_refusal('пароль неверен')

    local conn, err = p:take()

    t.assert_equals(conn, nil)
    t.assert_equals(
        err,
        'соединение не получено за 1 с: открыть соединение не удалось: пароль неверен'
    )

    -- Первая попытка открыла занятое, вторая и третья — в 1000 и в 1000.5:
    -- пауза не отменяется и здесь.
    t.assert_equals(service.lefts, { 1, 1, 0.5 })
    t.assert_equals(clock.monotonic(), 1001)
    t.assert_equals(p:stats().wait_timeouts, 1)
end

g.test_refusal_that_may_be_retried_keeps_the_wait = function()
    local p = helper.pool_of(service, { open_cooldown = 2, wait_timeout = 1 })

    service.failures = math.huge
    service.reason = setmetatable({ retriable = true }, {
        __tostring = function()
            return 'нет связи'
        end,
    })

    local conn, err = p:take()

    t.assert_equals(conn, nil)
    t.assert_equals(
        err,
        'соединение не получено за 1 с: открыть соединение не удалось: нет связи'
    )
    t.assert_equals(clock.monotonic(), 1001)
end

g.test_slow_refusal_to_open_does_not_make_the_wait_oversleep = function()
    -- Открытие уходит в сеть на своё время. Отметка, снятая до него,
    -- отстала бы на всё это время: ожидание проспало бы и паузу после
    -- отказа, и сам срок.
    local p = helper.pool_of(service, {
        open_cooldown = 0.5,
        wait_timeout = 5,
        open = function()
            service.attempts = service.attempts + 1
            clock.advance(1)

            return nil, service.reason
        end,
    })

    local conn, err = p:take()

    t.assert_equals(conn, nil)
    t.assert_equals(
        err,
        'соединение не получено за 5 с: открыть соединение не удалось: служба не отвечает'
    )

    -- Попытки в 0, 1.5 и 3.5 секунды, каждая длиной в секунду; третья
    -- назначает паузу до 6.5, и взявший уходит ровно в свой срок.
    t.assert_equals(service.attempts, 3)
    t.assert_equals(clock.monotonic(), 1005)
end

g.test_pause_that_ran_out_before_the_sleep_is_not_slept_to_the_deadline = function()
    -- Между отметкой отказа и сном пул ещё работает: собирает текст
    -- отказа, пишет журнал, а сборщик мусора вправе вклиниться в любую
    -- строку. Эта работа бывает длиннее короткой паузы, и пауза выходит
    -- раньше, чем взявший ляжет спать. Сон до побудки стал бы тогда сном
    -- до конца срока: будить некому, соединений в пуле нет. Работу здесь
    -- изображает текст отказа, который собирается полсекунды.
    service.failures = 1
    service.reason = setmetatable({}, {
        __tostring = function()
            clock.advance(0.5)

            return 'служба не отвечает'
        end,
    })

    local p = helper.pool_of(service, { size = 1, open_cooldown = 0.25, wait_timeout = 5 })

    t.assert_equals(p:take(), { id = 1 })
    t.assert_equals(service.attempts, 2)

    -- Вторая попытка — в тот же миг, как пул заметил, что пауза вышла,
    -- а не в конце срока.
    t.assert_equals(clock.monotonic(), 1000.5)
end

g.test_busy_pool_says_so_even_after_an_earlier_refusal_to_open = function()
    service.failures = 1

    local p = helper.pool_of(service, { size = 1, open_cooldown = 0.5, wait_timeout = 1 })

    t.assert_equals(p:take(), { id = 1 })

    -- Место в пуле кончилось, и прошлый отказ службы тут ни при чём:
    -- назвать его значит послать чинить не то.
    local second, err = p:take()

    t.assert_equals(second, nil)
    t.assert_equals(err, 'соединение не получено за 1 с: все 1 заняты')
end

g.test_deadline_that_the_scheduler_overshot_still_ends_the_wait = function()
    -- Планировщик будит не ровно в срок, а чуть позже. Ожидание, которое
    -- кончается только точным попаданием в срок, не кончается никогда:
    -- взявший крутится в цикле, пока кто-нибудь не заметит.
    local late, source = helper.clock({ overshoot = 0.25 })

    pool._set_source(source)

    local p = helper.pool_of(service, { size = 1, wait_timeout = 1 })

    p:take()

    local conn, err = p:take()

    t.assert_equals(conn, nil)
    t.assert_equals(err, 'соединение не получено за 1 с: все 1 заняты')
    t.assert_equals(late.monotonic(), 1001.25)
end

g.test_pool_opens_at_once_while_the_clock_shows_zero = function()
    -- Ноль — законное показание часов: монотонные ничего не обещают о своей
    -- точке отсчёта. Пул, заведённый при нуле на часах, обязан открывать
    -- сразу, а не ждать окончания паузы, которой не было.
    local zero, source = helper.clock({ at = 0 })

    pool._set_source(source)

    local p = helper.pool_of(service)

    t.assert_equals(p:take(), { id = 1 })
    t.assert_equals(zero.monotonic(), 0)
end

g.test_pause_starts_over_after_a_connection_finally_opened = function()
    service.failures = 1

    local p = helper.pool_of(service, { size = 2, open_cooldown = 0.5, wait_timeout = 1 })

    t.assert_equals(p:take(), { id = 1 })

    service.failures = math.huge

    local second, err = p:take(2)

    t.assert_equals(second, nil)
    t.assert_str_contains(err, 'служба не отвечает')

    -- Удачное открытие обнуляет счёт отказов подряд, и отсчёт пауз идёт
    -- заново: 0.5, 1, 2 — за две секунды помещаются три попытки. Без сброса
    -- паузы продолжились бы с 1, и попыток было бы две: служба,
    -- спотыкающаяся раз в час, к вечеру ждала бы переподключения полминуты,
    -- при том что она исправна.
    t.assert_equals(service.attempts, 5)
    t.assert_equals(clock.monotonic(), 1002.5)
end

g.test_pause_after_a_refusal_never_grows_past_half_a_minute = function()
    service.failures = 1

    local p = helper.pool_of(service, { open_cooldown = 40, wait_timeout = 31 })

    t.assert_equals(p:take(), { id = 1 })
    t.assert_equals(clock.monotonic(), 1030)
end

g.test_open_that_fell_is_a_refusal_like_any_other = function()
    local p = helper.pool_of(service, {
        wait_timeout = 1,
        open_cooldown = 2,
        open = function()
            error('сеть пропала')
        end,
    })

    local conn, err = p:take()

    t.assert_equals(conn, nil)
    t.assert_str_contains(err, 'сеть пропала')
    t.assert_equals(p:stats().open_failures, 1)
    t.assert_equals(p:stats().total, 0)
end

g.test_open_that_refused_without_a_reason_says_so = function()
    local p = helper.pool_of(service, {
        wait_timeout = 1,
        open_cooldown = 2,
        open = function()
            return nil
        end,
    })

    local _, err = p:take()

    t.assert_equals(
        err,
        'соединение не получено за 1 с: открыть соединение не удалось: причина не названа'
    )
end

g.test_connection_handed_out_by_open_twice_is_refused = function()
    local same = { id = 'одно и то же' }

    local p = helper.pool_of(service, {
        size = 2,
        wait_timeout = 1,
        open_cooldown = 2,
        open = function()
            return same
        end,
    })

    t.assert_equals(p:take(), same)

    local second, err = p:take()

    t.assert_equals(second, nil)
    t.assert_str_contains(err, 'open вернул соединение, которое уже в пуле')

    -- Место, занятое под открытие, возвращено: иначе пул потерял бы его
    -- навсегда и однажды перестал бы открывать что-либо.
    t.assert_equals(p:stats().total, 1)
end

g.test_returning_a_stranger_is_refused = function()
    local p = helper.pool_of(service)
    local ok, err = p:give({ id = 'чужое' })

    t.assert_equals(ok, false)
    t.assert_equals(err, 'соединение не из этого пула')
    t.assert_equals(p:stats().idle, 0)
end

g.test_returning_the_same_connection_twice_is_refused = function()
    local p = helper.pool_of(service)
    local conn = p:take()

    t.assert_equals(p:give(conn), true)

    local ok, err = p:give(conn)

    t.assert_equals(ok, false)
    t.assert_equals(err, 'соединение уже возвращено')
    t.assert_equals(p:stats().idle, 1)
    t.assert_equals(p:stats().gives, 1)
end

g.test_dropping_a_stranger_is_refused = function()
    local p = helper.pool_of(service)
    local ok, err = p:drop({ id = 'чужое' })

    t.assert_equals(ok, false)
    t.assert_equals(err, 'соединение не из этого пула')
end

g.test_dropped_connection_is_closed_and_forgotten = function()
    local p = helper.pool_of(service)
    local conn = p:take()

    t.assert_equals(p:drop(conn), true)
    t.assert_equals(p:stats().busy, 0)
    t.assert_equals(p:stats().total, 0)
    t.assert_equals(p:stats().drops, 1)
    t.assert_equals(service.closed, { 1 })
    t.assert_equals(p:give(conn), false)
end

g.test_idle_connection_can_be_dropped_too = function()
    local p = helper.pool_of(service)
    local conn = p:take()

    p:give(conn)

    t.assert_equals(p:drop(conn), true)
    t.assert_equals(p:stats().idle, 0)
    t.assert_equals(p:stats().busy, 0)
    t.assert_equals(p:stats().total, 0)
end

g.test_with_returns_what_the_body_returned_and_gives_the_connection_back = function()
    local p = helper.pool_of(service)
    local answer, err = p:with(function(conn)
        return conn.id * 10
    end)

    t.assert_equals(answer, 10)
    t.assert_equals(err, nil)
    t.assert_equals(p:stats().idle, 1)
    t.assert_equals(p:stats().busy, 0)
    t.assert_equals(p:stats().gives, 1)
end

g.test_with_passes_the_refusal_of_the_body_through = function()
    local p = helper.pool_of(service)
    local answer, err = p:with(function()
        return nil, 'нет такой таблицы'
    end)

    t.assert_equals(answer, nil)
    t.assert_equals(err, 'нет такой таблицы')

    -- Отказ — это ответ, а не поломка: соединение исправно и возвращается.
    t.assert_equals(p:stats().idle, 1)
    t.assert_equals(p:stats().drops, 0)
end

--- Сброс, который не пускает в пул соединение с открытой транзакцией.
---
--- Транзакцию здесь изображает метка на соединении: пулу всё равно, как
--- клиент узнаёт о ней, лишь бы узнавал без сети.
---@param conn table
---@return boolean
local function refuses_open_transaction(conn)
    return not conn.in_transaction
end

--- Тело, которое отказывает посреди им же открытой транзакции.
---@param conn table
---@return nil
---@return string
local function refuses_inside_a_transaction(conn)
    conn.in_transaction = true

    return nil, 'нарушено ограничение уникальности'
end

g.test_refusal_of_the_body_leaves_its_transaction_to_the_next_taker = function()
    -- Опасное место, которое называет документ: пул транзакций не видит,
    -- и без сброса отказ тела отдаёт соединение следующему вместе с тем,
    -- что тело не закрыло, — тот зафиксирует чужую работу.
    local p = helper.pool_of(service)

    p:with(refuses_inside_a_transaction)

    t.assert_equals(p:take(), { id = 1, in_transaction = true })
end

g.test_reset_throws_away_the_transaction_a_refusal_left_open = function()
    local p = helper.pool_of(service, { reset = refuses_open_transaction })
    local answer, err = p:with(refuses_inside_a_transaction)

    -- Выброс соединения — забота пула, а не повод подменять ответ тела.
    t.assert_equals(answer, nil)
    t.assert_equals(err, 'нарушено ограничение уникальности')
    t.assert_equals(p:stats().gives, 1)
    t.assert_equals(p:stats().idle, 0)
    t.assert_equals(p:stats().total, 0)
    t.assert_equals(service.closed, { 1 })

    -- Следующий взявший получает новое соединение, без чужой работы.
    t.assert_equals(p:take(), { id = 2 })
end

g.test_reset_keeps_the_connection_of_a_refusal_outside_a_transaction = function()
    -- Сброс отсекает только соединение в транзакции: платить новым
    -- соединением за каждое «нет такой записи» защита не должна.
    local p = helper.pool_of(service, { reset = refuses_open_transaction })
    local answer, err = p:with(function()
        return nil, 'нет такой записи'
    end)

    t.assert_equals(answer, nil)
    t.assert_equals(err, 'нет такой записи')
    t.assert_equals(p:stats().idle, 1)
    t.assert_equals(service.closed, {})
    t.assert_equals(p:take(), { id = 1 })
end

g.test_connection_of_a_fallen_body_is_thrown_away = function()
    local p = helper.pool_of(service)
    local answer, err = p:with(function()
        error('ответ не разобрался', 0)
    end)

    t.assert_equals(answer, nil)
    t.assert_equals(err, 'ответ не разобрался')
    t.assert_equals(p:stats().drops, 1)
    t.assert_equals(p:stats().idle, 0)
    t.assert_equals(p:stats().total, 0)
    t.assert_equals(service.closed, { 1 })
    t.assert_equals(journal.logged('работа с соединением сорвалась'), true)
end

g.test_with_reports_that_no_connection_was_given = function()
    local p = helper.pool_of(service, { size = 1, wait_timeout = 1 })

    p:take()

    local answer, err = p:with(function()
        return 'до тела не дойдёт'
    end)

    t.assert_equals(answer, nil)
    t.assert_equals(err, 'соединение не получено за 1 с: все 1 заняты')
end

g.test_connection_that_could_not_be_scrubbed_is_not_taken_back = function()
    local p = helper.pool_of(service, {
        reset = function()
            return false
        end,
    })

    t.assert_equals(p:give(p:take()), true)
    t.assert_equals(p:stats().idle, 0)
    t.assert_equals(p:stats().total, 0)
    t.assert_equals(p:stats().gives, 1)
    t.assert_equals(service.closed, { 1 })
end

g.test_scrubbing_that_fell_costs_the_connection_too = function()
    local p = helper.pool_of(service, {
        reset = function()
            error('транзакция не откатилась')
        end,
    })

    t.assert_equals(p:give(p:take()), true)
    t.assert_equals(p:stats().total, 0)
end

g.test_scrubbed_connection_returns_to_the_pool = function()
    local scrubbed = 0

    local p = helper.pool_of(service, {
        reset = function()
            scrubbed = scrubbed + 1

            return true
        end,
    })

    t.assert_equals(p:give(p:take()), true)
    t.assert_equals(scrubbed, 1)
    t.assert_equals(p:stats().idle, 1)
end

g.test_close_that_failed_is_only_written_down = function()
    local p = helper.pool_of(service, {
        close = function()
            error('сокет уже мёртв')
        end,
    })

    p:give(p:take())
    p:close()

    t.assert_equals(p:stats().discarded, 1)
    t.assert_equals(journal.logged('закрыть соединение не удалось'), true)
end

g.test_closed_pool_hands_out_nothing = function()
    local p = helper.pool_of(service)

    p:give(p:take())

    t.assert_equals(p:close(), true)
    t.assert_equals(p:is_closed(), true)
    t.assert_equals(p:stats().idle, 0)
    t.assert_equals(p:stats().closed, true)
    t.assert_equals(service.closed, { 1 })

    local conn, err = p:take()

    t.assert_equals(conn, nil)
    t.assert_equals(err, 'пул закрыт')

    local again, said = p:close()

    t.assert_equals(again, false)
    t.assert_equals(said, 'пул уже закрыт')
end

g.test_closing_the_pool_closes_every_free_connection = function()
    local p = helper.pool_of(service, { size = 3 })
    local first = p:take()
    local second = p:take()
    local third = p:take()

    p:give(first)
    p:give(second)
    p:give(third)
    t.assert_equals(p:close(), true)

    -- Закрываются все до единого и с конца списка: последним положили —
    -- первым закрыли, и ни одного не перешагнули.
    t.assert_equals(service.closed, { 3, 2, 1 })
    t.assert_equals(p:stats().total, 0)
    t.assert_equals(p:stats().discarded, 3)
end

g.test_busy_connection_is_closed_when_it_comes_back = function()
    local p = helper.pool_of(service)
    local conn = p:take()

    p:close()

    -- Занятое не отнимают: файбер, работающий по соединению, получил бы
    -- обрыв посреди запроса.
    t.assert_equals(service.closed, {})
    t.assert_equals(p:give(conn), true)
    t.assert_equals(service.closed, { 1 })
    t.assert_equals(p:stats().total, 0)
end

g.test_connection_that_came_back_to_a_closed_pool_is_not_scrubbed = function()
    -- Сбрасывать соединение, которое тут же закроется, — лишний поход
    -- в сеть, и на молчащем сервере он задержал бы возврат без всякой
    -- пользы.
    local scrubbed = {}

    local p = helper.pool_of(service, {
        reset = function(conn)
            table.insert(scrubbed, conn.id)

            return true
        end,
    })

    local conn = p:take()

    t.assert_equals(p:close(), true)
    t.assert_equals(p:give(conn), true)
    t.assert_equals(scrubbed, {})
    t.assert_equals(service.closed, { 1 })
    t.assert_equals(p:stats().idle, 0)
    t.assert_equals(p:stats().total, 0)
end

g.test_wait_that_was_broken_gives_up_at_once = function()
    local p = helper.pool_of(service, { size = 1, wait_timeout = 5 })

    p:take()
    pool._set_source({ cond = helper.broken_cond('файбер отменён') })

    local conn, err = p:take()

    t.assert_equals(conn, nil)
    t.assert_equals(err, 'ожидание соединения прервано: файбер отменён')
end

g.test_leak_is_named_once_and_the_connection_is_left_alone = function()
    local p = helper.pool_of(service, { leak_timeout = 1 })

    p:take()
    clock.advance(5)
    p:sweep()

    t.assert_equals(p:stats().leaks, 1)
    t.assert_equals(p:stats().busy, 1)
    t.assert_equals(p:stats().total, 1)
    t.assert_equals(journal.logged('соединение держат дольше срока'), true)

    -- Сколько держат и сколько раз выдавалось — это и есть след, по которому
    -- утечку ищут: без них в журнале «где-то что-то течёт».
    t.assert_equals(journal.logged('held=5'), true)
    t.assert_equals(journal.logged('uses=1'), true)

    clock.advance(100)
    p:sweep()

    -- Второй раз о том же удержании не кричат: журнал забился бы одной
    -- и той же строкой раз в такт уборки.
    t.assert_equals(p:stats().leaks, 1)
end

g.test_leak_is_named_the_moment_the_time_is_up = function()
    local p = helper.pool_of(service, { leak_timeout = 1 })

    p:take()
    clock.advance(1)
    p:sweep()

    t.assert_equals(p:stats().leaks, 1)
end

g.test_leak_is_not_named_before_its_time = function()
    local p = helper.pool_of(service, { leak_timeout = 1 })

    p:take()
    clock.advance(0.999)
    p:sweep()

    t.assert_equals(p:stats().leaks, 0)
    t.assert_equals(journal.logged('соединение держат дольше срока'), false)
end

g.test_leaks_are_not_looked_for_when_nobody_asked = function()
    local p = helper.pool_of(service, { leak_timeout = 0 })

    p:take()
    clock.advance(100000)
    p:sweep()

    t.assert_equals(p:stats().leaks, 0)
end

g.test_leak_is_named_again_after_the_connection_went_out_a_second_time = function()
    local p = helper.pool_of(service, { leak_timeout = 1 })
    local conn = p:take()

    clock.advance(5)
    p:sweep()
    p:give(conn)
    p:take()
    clock.advance(5)
    p:sweep()

    t.assert_equals(p:stats().leaks, 2)
    t.assert_equals(journal.logged('uses=2'), true)
end

g.test_janitor_closes_idle_connections_without_being_asked = function()
    local p = helper.pool_of(service, { idle_timeout = 10, sweep_interval = 0.01 })

    p:give(p:take())
    clock.advance(10)

    -- Такт уборки идёт настоящими часами, а простой считается
    -- подменёнными: ждать здесь приходится по-настоящему, зато недолго.
    for _ = 1, 200 do
        if p:stats().idle == 0 then
            break
        end

        fiber.sleep(0.01)
    end

    t.assert_equals(p:stats().idle, 0)
    t.assert_equals(p:stats().discarded, 1)
    t.assert_equals(service.closed, { 1 })
    t.assert_equals(p:close(), true)
end

g.test_broken_sweep_is_only_written_down = function()
    local p = helper.pool_of(service)

    p:_sweep_failed('уборщик споткнулся')

    t.assert_equals(journal.logged('уборка пула не удалась'), true)
    t.assert_equals(journal.logged('уборщик споткнулся'), true)
end

g.test_stats_tell_what_happened_while_nobody_was_looking = function()
    local p = helper.pool_of(service, { size = 1, wait_timeout = 1, name = 'postgres' })
    local conn = p:take()

    p:give(conn)
    conn = p:take()
    p:drop(conn)

    t.assert_equals(p:stats(), {
        name = 'postgres',
        size = 1,
        busy = 0,
        idle = 0,
        waiting = 0,
        total = 0,
        closed = false,
        opened = 1,
        discarded = 1,
        open_failures = 0,
        takes = 2,
        gives = 1,
        drops = 1,
        waits = 0,
        wait_timeouts = 0,
        leaks = 0,
    })
end

g.test_stats_show_the_settings_but_never_the_tools = function()
    -- Пароль живёт внутри `open`, и наружу пул отдаёт только числа: отдать
    -- сами средства значило бы отдать и замыкание с паролем.
    local p = helper.pool_of(service, { name = 'redis' })
    local shown = p:stats()

    t.assert_equals(shown.name, 'redis')
    t.assert_equals(shown.open, nil)
    t.assert_equals(shown.close, nil)
    t.assert_equals(shown.alive, nil)
end

g.test_shared_pool_is_not_built_before_it_is_asked_for = function()
    t.assert_equals(pool.status(), { configured = false, created = false })

    pool.configure({ open = service.open, close = service.close, sweep_interval = 0 })

    t.assert_equals(pool.status(), { configured = true, created = false })
    t.assert_equals(service.attempts, 0)

    local shared = pool.default()

    t.assert_equals(pool.default(), shared)
    t.assert_equals(pool.status().created, true)
    t.assert_equals(pool.status().configured, true)
    t.assert_equals(pool.status().size, 8)
end

g.test_shared_pool_needs_settings_first = function()
    local ok, err = pcall(pool.default)

    t.assert_equals(ok, false)
    t.assert_str_contains(
        tostring(err),
        'пул не настроен: позовите pool.configure до pool.default'
    )
end

g.test_settings_are_checked_when_they_are_given_not_when_they_are_used = function()
    local ok, err = pcall(pool.configure, { open = service.open, size = -1 })

    t.assert_equals(ok, false)
    t.assert_str_contains(tostring(err), 'настройка size не может быть меньше 1')
    t.assert_equals(pool.status(), { configured = false, created = false })
end

g.test_misspelt_setting_is_blamed_on_the_line_that_made_the_pool = function()
    -- Вызов нарочно не хвостовой и идёт из замыкания, а не прямо из
    -- `pcall`: у C-кадра места нет, а хвостовой кадр LuaJIT снимает.
    for _, make in ipairs({ pool.new, pool.configure }) do
        local line
        local ok, err = pcall(function()
            line = assert(debug.getinfo(1, 'l')).currentline + 1
            make({ open = service.open, idle_timout = 5 })
        end)

        t.assert_equals(ok, false)
        t.assert_equals(
            tostring(err),
            ('%s:%d: настройки пула: ключа «idle_timout» нет, есть %s'):format(
                THIS_FILE,
                line,
                helper.KNOWN_SETTINGS
            )
        )
    end

    t.assert_equals(pool.status(), { configured = false, created = false })
end

g.test_callable_tables_serve_as_tools = function()
    -- Пул общий нарочно: `default` заводит его из уже проверенных
    -- настроек, и средства-таблицы проходят проверку второй раз.
    local open = setmetatable({}, {
        __call = function(_, left)
            return service.open(left)
        end,
    })

    local closed = {}
    local close = setmetatable({}, {
        __call = function(_, conn)
            table.insert(closed, conn.id)
        end,
    })

    pool.configure({ open = open, close = close, size = 1, sweep_interval = 0 })

    local p = pool.default()
    local conn = p:take()

    t.assert_equals(conn, { id = 1 })
    t.assert_equals(p:drop(conn), true)
    t.assert_equals(closed, { 1 })
end

g.test_new_settings_close_the_pool_that_was_shared = function()
    local settings = { open = service.open, close = service.close, sweep_interval = 0 }

    pool.configure(settings)

    local first = pool.default()

    first:give(first:take())
    pool.configure(settings)

    t.assert_equals(first:is_closed(), true)
    t.assert_equals(service.closed, { 1 })
    t.assert_not_equals(pool.default(), first)
end

g.test_forgetting_the_shared_pool_closes_it = function()
    pool.configure({ open = service.open, close = service.close, sweep_interval = 0 })

    local shared = pool.default()

    pool.reset()

    t.assert_equals(shared:is_closed(), true)
    t.assert_equals(pool.status(), { configured = false, created = false })
end

g.test_separate_pools_share_nothing = function()
    local other = helper.service()
    local first = helper.pool_of(service, { size = 1 })
    local second = helper.pool_of(other, { size = 1 })

    first:take()

    t.assert_equals(second:take(), { id = 1 })
    t.assert_equals(first:stats().total, 1)
    t.assert_equals(second:stats().total, 1)
    t.assert_equals(service.attempts, 1)
    t.assert_equals(other.attempts, 1)
end
