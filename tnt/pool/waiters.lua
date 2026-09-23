--- Очередь тех, кто ждёт свободного соединения.
---
--- Когда соединений в пуле больше нет, взявший обязан подождать. Ждать
--- можно двумя способами, и разница между ними — это разница между
--- работающим узлом и узлом, который «почему-то греет процессор». Опрос
--- в цикле («не освободилось ли?») занимает поток планировщика ровно тем,
--- что ничего не делает; условная переменная снимает файбер с очереди
--- планировщика совсем, и он не стоит узлу ничего до побудки.
---
--- Очередь честная: кто пришёл раньше, тот получит соединение раньше.
--- Своя условная переменная на каждого ожидающего, а не одна на всех, —
--- именно ради этого: общая переменная будит всех разом, и соединение
--- достаётся тому, кого планировщик поставил первым, а не тому, кто дольше
--- ждёт. На пуле из восьми соединений и сотне файберов это означает, что
--- кому-то не достанется ничего и через минуту.
---
--- Побудка не запоминается: сигнал, посланный до `wait`, пропадает.
--- Поэтому ожидающий встаёт в очередь и засыпает без единой уступки
--- управления между этими двумя действиями, а всякий, кто уходит из головы
--- очереди, будит нового первого — иначе побудка, доставшаяся уходящему,
--- ушла бы вместе с ним, и очередь спала бы при свободном соединении.

---@class TntPoolTicket
---@field cond table Условная переменная этого ожидающего

---@class TntPoolWaiters
---@field tickets TntPoolTicket[] Ожидающие в порядке прихода
---@field make_cond fun(): table Откуда брать условную переменную
local Module = {}
Module.__index = Module

--- Заводит пустую очередь.
---
--- Условная переменная берётся аргументом, а не прямо из `fiber`: проверке
--- нужна такая, у которой ожидание не занимает настоящего времени, иначе
--- проверка пятисекундного срока идёт пять секунд.
---@param make_cond fun(): table
---@return TntPoolWaiters
function Module.new(make_cond)
    return setmetatable({ tickets = {}, make_cond = make_cond }, Module)
end

--- Встаёт в хвост очереди.
---@return TntPoolTicket ticket Место в очереди; с ним же и уходить
function Module:push()
    local ticket = { cond = self.make_cond() }

    table.insert(self.tickets, ticket)

    return ticket
end

--- Спит до побудки или до срока — что наступит раньше.
---
--- Функция модуля, а не метод очереди: сон ничего в очереди не меняет,
--- и очередь ему не нужна — нужен только билет. Метод, которому не нужен
--- хозяин, однажды начинает его трогать без повода.
---
--- Отмена файбера в Tarantool выходит из ожидания исключением, а не
--- ответом. Ронять им пул нельзя: отменяют обычно весь узел, и файбер,
--- упавший с соединением в руках, не вернул бы его в пул.
---@param ticket TntPoolTicket
---@param seconds number
---@return boolean woken Разбудили; `false` — вышел срок
---@return string|nil err Ожидание сорвалось, ждать больше нельзя
function Module.wait_on(ticket, seconds)
    local ok, woken = pcall(ticket.cond.wait, ticket.cond, seconds)

    if not ok then
        return false, tostring(woken)
    end

    return woken == true
end

--- Первый ли он в очереди.
---
--- Соединение отдаётся только первому. Без этого правила пришедший
--- последним успевал бы забрать освободившееся соединение раньше, чем
--- планировщик доберётся до разбуженного, — и очередь переставала бы быть
--- очередью ровно под той нагрузкой, ради которой заведена.
---@param ticket TntPoolTicket|nil
---@return boolean
function Module:is_head(ticket)
    return ticket ~= nil and self.tickets[1] == ticket
end

--- Пуста ли очередь.
---@return boolean
function Module:empty()
    return self.tickets[1] == nil
end

--- Сколько сейчас ждут.
---@return integer
function Module:count()
    return #self.tickets
end

--- Убирает ожидающего из очереди.
---
--- Ушедший из головы будит нового первого: побудка могла достаться уже
--- ему, а унести её с собой значит оставить очередь спящей при свободном
--- соединении.
---@param ticket TntPoolTicket|nil
---@return boolean removed Стоял ли он в очереди вообще
function Module:remove(ticket)
    if ticket == nil then
        return false
    end

    for index, waiting in ipairs(self.tickets) do
        if waiting == ticket then
            table.remove(self.tickets, index)

            if index == 1 then
                self:wake_one()
            end

            return true
        end
    end

    return false
end

--- Будит первого в очереди. Пустую очередь будить не жалко.
function Module:wake_one()
    local ticket = self.tickets[1]

    if ticket ~= nil then
        ticket.cond:signal()
    end
end

--- Будит всех: пул закрывается, и ждать больше нечего.
function Module:wake_all()
    for _, ticket in ipairs(self.tickets) do
        ticket.cond:broadcast()
    end
end

return Module
