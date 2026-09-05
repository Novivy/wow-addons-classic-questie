---@class QuestieAuto
local QuestieAuto = QuestieLoader:CreateModule("QuestieAuto");
local _QuestieAuto = QuestieAuto.private
---@type QuestieDB
local QuestieDB = QuestieLoader:ImportModule("QuestieDB");

local shouldRunAuto = true
local doneTalking = false

local cameFromProgressEvent = false
local isAllowedNPC = false
local lastAmountOfAvailableQuests = 0
local lastNPCTalkedTo
local doneWithAccept = false
local lastIndexTried = 1
local lastEvent

-- The gossip available/active quest list is NOT refreshed instantly after a
-- SelectGossipAvailableQuest/SelectGossipActiveQuest call. The server frequently
-- fires several GOSSIP_SHOW events in quick succession before the list updates,
-- which made QuestieAuto re-select the very same quest over and over, spamming
-- "You are already on that quest". This throttle suppresses those duplicate
-- events. It is reset whenever the gossip state actually changes (new NPC or a
-- different number of available quests), so genuine sequential accepts/turn-ins
-- still happen immediately.
local lastGossipActionTime = 0
local GOSSIP_AUTO_THROTTLE = 0.4

-- QUEST_DETAIL can fire more than once for the same quest (the detail frame
-- re-shows before the accept registers), which made QuestieAuto send a second
-- AcceptQuest for a quest it just accepted -> "You are already on that quest".
-- Remember the last quest we auto-accepted and refuse to accept the same id
-- again within a short window. A quest can never legitimately be re-accepted
-- this fast, so this only ever drops duplicate accepts.
local lastAcceptedQuestId
local lastAcceptTime = 0
local QUEST_ACCEPT_THROTTLE = 1.5

-- Same story on the turn-in side: the server can send the reward offer twice for
-- one quest (a whole group turning the same quest in at the same NPC makes this
-- happen a lot). The first GetQuestReward succeeds and the quest leaves the log,
-- the second is silently dropped by the server because we no longer have that
-- quest -- and nothing closes the reward panel, so the "Complete Quest" window
-- stays on screen for an already-completed quest.
local lastTurnedInQuestId
local lastTurnInTime = 0
local QUEST_TURN_IN_THROTTLE = 1.5

-- QUEST_ACCEPT_CONFIRM (escort / shared quests) fires once per nearby party
-- member that starts the quest. Confirming every single time re-sends an accept
-- for a quest we already took -> "You are already on that quest".
local lastConfirmTime = 0
local QUEST_CONFIRM_THROTTLE = 1.5

--- Authoritative "am I already on this quest?" check. Time windows can never be
--- tight enough on a laggy server or when a duplicate event is delayed by a
--- group turn-in chain; the quest log cannot lie.
local function _IsQuestInLog(questId)
    if (not questId) or questId <= 0 then
        return false
    end
    return (GetQuestLogIndexByID(questId) or 0) > 0
end

--- Title-based variant, for events that give us a name but no quest id
--- (QUEST_ACCEPT_CONFIRM).
local function _IsQuestTitleInLog(title)
    if type(title) ~= "string" or title == "" then
        return false
    end
    for index = 1, GetNumQuestLogEntries() do
        local logTitle, _, _, isHeader = GetQuestLogTitle(index)
        if (not isHeader) and logTitle == title then
            return true
        end
    end
    return false
end

--- True if ANY of the given values is the title of a quest we are on. Used when
--- an event hands us several strings and we do not want to depend on their order.
local function _AnyQuestTitleInLog(...)
    for i = 1, select("#", ...) do
        if _IsQuestTitleInLog((select(i, ...))) then
            return true
        end
    end
    return false
end

--- Dismiss a stale quest dialog. CloseQuest() is the direct API but is not
--- guaranteed to exist on every client build, and the previous code guarded it
--- with `if CloseQuest then`, which silently did nothing when it was missing --
--- leaving exactly the stuck window we are trying to get rid of. Fall back to
--- hiding QuestFrame, whose OnHide does the same server-side bookkeeping.
local function _CloseQuestFrame()
    if CloseQuest then
        CloseQuest()
    end
    if QuestFrame and QuestFrame:IsVisible() then
        if HideUIPanel then
            HideUIPanel(QuestFrame)
        else
            QuestFrame:Hide()
        end
    end
end

local MOP_INDEX_AVAILABLE = 7 -- was '5' in Cataclysm
local MOP_INDEX_COMPLETE = 6 -- was '4' in Cataclysm

 -- forward declarations
local _SelectAvailableQuest

function QuestieAuto:GOSSIP_SHOW(event, ...)
    Questie:Debug(Questie.DEBUG_DEVELOP, "[EVENT] GOSSIP_SHOW", event, ...)
    doneTalking = false

    if (not shouldRunAuto) then
        return
    elseif _QuestieAuto:IsBindTrue(Questie.db.char.autoModifier) then
        shouldRunAuto = false
        Questie:Debug(Questie.DEBUG_DEVELOP, "Modifier-Key down: Disabling QuestieAuto for now")
        return
    end
    lastEvent = "GOSSIP_SHOW"

    local availableQuests = {GetGossipAvailableQuests()}
    local currentNPC = UnitName("target")
    if lastNPCTalkedTo ~= currentNPC or #availableQuests ~= lastAmountOfAvailableQuests then
        Questie:Debug(Questie.DEBUG_DEVELOP, "Greeted by a new NPC")
        lastNPCTalkedTo = currentNPC
        isAllowedNPC = _QuestieAuto:IsAllowedNPC()
        lastIndexTried = 1
        lastAmountOfAvailableQuests = #availableQuests
        doneWithAccept = false
        -- The gossip state genuinely changed, so allow the next action right away.
        lastGossipActionTime = 0
    end

    if cameFromProgressEvent then
        Questie:Debug(Questie.DEBUG_DEVELOP, "Last event was Progress")
        cameFromProgressEvent = false
        lastIndexTried = lastIndexTried + MOP_INDEX_AVAILABLE
    elseif (GetTime() - lastGossipActionTime) < GOSSIP_AUTO_THROTTLE then
        -- Suppress duplicate GOSSIP_SHOW events for the same, unchanged gossip state.
        -- Without this, the same quest gets selected repeatedly before the list
        -- updates, spamming "You are already on that quest". Progress-driven
        -- re-entry (handled above) is intentionally never throttled.
        Questie:Debug(Questie.DEBUG_DEVELOP, "Throttling duplicate GOSSIP_SHOW (auto-accept/complete)")
        return
    end

    if Questie.db.char.autoaccept and (not doneWithAccept) and isAllowedNPC then
        if lastIndexTried < #availableQuests then
            Questie:Debug(Questie.DEBUG_DEVELOP, "Checking available quests from gossip")
            lastGossipActionTime = GetTime()
            _QuestieAuto:AcceptQuestFromGossip(lastIndexTried, availableQuests, MOP_INDEX_AVAILABLE)
            return
        else
            Questie:Debug(Questie.DEBUG_DEVELOP, "DONE. Checked all available quests")
            doneWithAccept = true
            lastIndexTried = 1
        end
    end

    if Questie.db.char.autocomplete and isAllowedNPC then
        Questie:Debug(Questie.DEBUG_DEVELOP, "Checking active quests from gossip")
        local completeQuests = {GetGossipActiveQuests()}

        if #completeQuests > 0 then
            lastGossipActionTime = GetTime()
        end
        -- Select ONE quest per event. Selecting every completable quest in the
        -- same frame fires N SelectGossipActiveQuest packets at once, and the
        -- server answers each of them, interleaving progress/detail frames and
        -- driving the accept path into re-taking a quest. GOSSIP_SHOW fires
        -- again after each turn-in, so the rest still get handled in sequence.
        for index=1, #completeQuests, MOP_INDEX_COMPLETE do
            if _QuestieAuto:CompleteQuestFromGossip(index, completeQuests, MOP_INDEX_COMPLETE) then
                return
            end
        end
        Questie:Debug(Questie.DEBUG_DEVELOP, "DONE. Checked all complete quests")
    end
end

function QuestieAuto:QUEST_PROGRESS(event, ...)
    Questie:Debug(Questie.DEBUG_DEVELOP, "[EVENT] QUEST_PROGRESS", event, ...)
    doneTalking = false

    if (not shouldRunAuto) then
        return
    elseif _QuestieAuto:IsBindTrue(Questie.db.char.autoModifier) then
        shouldRunAuto = false
        Questie:Debug(Questie.DEBUG_DEVELOP, "Modifier-Key down: Disabling QuestieAuto for now")
        return
    end

    if Questie.db.char.autocomplete then
        if _QuestieAuto:IsAllowedNPC() and _QuestieAuto:IsAllowedQuest() then
            if IsQuestCompletable() then
                CompleteQuest()
                return
            else
                Questie:Debug(Questie.DEBUG_DEVELOP, "Quest not completeable. Index", lastIndexTried)
            end
        end

        -- Close the QuestFrame if no quest is completeable again
        if QuestFrameGoodbyeButton and lastEvent ~= nil then
            QuestFrameGoodbyeButton:Click()
        end
        cameFromProgressEvent = true
    end
    lastEvent = "QUEST_PROGRESS"
end

_SelectAvailableQuest = function (index)
    Questie:Debug(Questie.DEBUG_DEVELOP, "Selecting the " .. index .. ". available quest")
    SelectAvailableQuest(index)
end

--- Accept the currently-shown quest unless we just accepted this same quest id
--- (QUEST_DETAIL can fire twice for one quest, e.g. on the turn-in -> follow-up
--- transition, which otherwise sends a second AcceptQuest -> "already on that quest").
local _AutoAcceptQuest = function(questId, quest)
    -- Two ways this detail frame can be stale:
    --  * the quest is already in our log -- the offer was re-sent (gossip list
    --    re-fired after a turn-in, or a party member shared the quest we just
    --    took ourselves). This is authoritative and has no time limit.
    --  * we fired AcceptQuest a moment ago and the log has not caught up yet.
    -- Either way, accepting again just yields "You are already on that quest"
    -- and leaves the window open, so dismiss it instead.
    if _IsQuestInLog(questId)
        or (questId == lastAcceptedQuestId and (GetTime() - lastAcceptTime) < QUEST_ACCEPT_THROTTLE) then
        Questie:Debug(Questie.DEBUG_DEVELOP, "Skipping duplicate auto-accept for quest", questId, "- closing stale detail frame")
        _CloseQuestFrame()
        return
    end
    if (not quest:IsTrivial()) or Questie.db.char.acceptTrivial then
        Questie:Debug(Questie.DEBUG_INFO, "Questie Auto-Acceping quest")
        lastAcceptedQuestId = questId
        lastAcceptTime = GetTime()
        AcceptQuest()
    end
end

function QuestieAuto:QUEST_ACCEPT_CONFIRM(event, ...)
    Questie:Debug(Questie.DEBUG_DEVELOP, "[EVENT] QUEST_ACCEPT_CONFIRM", event, ...)
    lastEvent = "QUEST_ACCEPT_CONFIRM"
    doneTalking = false

    -- Escort stuff
    if (not Questie.db.char.autoaccept) then
        return
    end

    -- In a group this fires once per party member that starts the escort, so an
    -- unconditional ConfirmAcceptQuest() re-accepts a quest we already have and
    -- spams "You are already on that quest".
    --
    -- The event payload contains the quest title alongside other strings, and
    -- because these handlers are declared with ':' while CallbackHandler invokes
    -- them as plain functions, 'self' eats the event name and 'event' holds the
    -- game's first argument. Rather than depend on that offset or on the payload
    -- order, test every string we were handed: a player name or an event name can
    -- never match a title in our own quest log, so a false positive is impossible.
    if _AnyQuestTitleInLog(event, ...) then
        Questie:Debug(Questie.DEBUG_DEVELOP, "Already on the quest offered by QUEST_ACCEPT_CONFIRM - not confirming again")
        return
    end

    -- Backstop for the window where we confirmed but the quest log has not
    -- updated yet: allow at most one confirm per throttle period. Two genuinely
    -- different escorts starting within the same 1.5s is not a real scenario;
    -- worst case the player clicks the popup themselves.
    local now = GetTime()
    if (now - lastConfirmTime) < QUEST_CONFIRM_THROTTLE then
        Questie:Debug(Questie.DEBUG_DEVELOP, "Throttling duplicate QUEST_ACCEPT_CONFIRM")
        return
    end

    lastConfirmTime = now
    ConfirmAcceptQuest()
end

function QuestieAuto:QUEST_GREETING(event, ...)
    Questie:Debug(Questie.DEBUG_DEVELOP, "[EVENT] QUEST_GREETING", event, GetNumActiveQuests(), ...)
    lastEvent = "QUEST_GREETING"
    doneTalking = false

    if (not shouldRunAuto) then
        return
    elseif _QuestieAuto:IsBindTrue(Questie.db.char.autoModifier) then
        shouldRunAuto = false
        Questie:Debug(Questie.DEBUG_DEVELOP, "Modifier-Key down: Disabling QuestieAuto for now")
        return
    end

    if cameFromProgressEvent then
        Questie:Debug(Questie.DEBUG_DEVELOP, "Last event was Progress")
        cameFromProgressEvent = false
        lastIndexTried = lastIndexTried + 1
    end

    -- Quest already taken
    if (Questie.db.char.autocomplete) then
        -- One selection per event only, see the matching comment in GOSSIP_SHOW.
        for index = 1, GetNumActiveQuests() do
            local quest, isComplete = GetActiveTitle(index)
            Questie:Debug(Questie.DEBUG_DEVELOP, quest, isComplete)
            if isComplete then
                SelectActiveQuest(index)
                return
            end
        end
    end

    if (Questie.db.char.autoaccept) then
        local availableQuestsCount = GetNumAvailableQuests()
        if lastIndexTried == 0 or lastIndexTried > availableQuestsCount then
            lastIndexTried = 1
        end
        Questie:Debug(Questie.DEBUG_DEVELOP, "lastIndex:", lastIndexTried)
        -- '<=', not '<': lastIndexTried is a 1-based quest ordinal here, so the
        -- strict comparison skipped the final quest. With one quest left the test
        -- read 1 < 1 and nothing was ever selected, which is why the last
        -- available quest at a multi-quest NPC never got auto-accepted. Each
        -- accept shrinks the list and re-fires the greeting, so this terminates
        -- once the count reaches zero.
        if availableQuestsCount > 0 and lastIndexTried <= availableQuestsCount then
            _SelectAvailableQuest(lastIndexTried)
        end
    end
end


function QuestieAuto:QUEST_DETAIL(event, ...)
    Questie:Debug(Questie.DEBUG_DEVELOP, "[EVENT] QUEST_DETAIL", event, ...)
    lastEvent = "QUEST_DETAIL"
    doneTalking = false

    if (not shouldRunAuto) then
        return
    elseif _QuestieAuto:IsBindTrue(Questie.db.char.autoModifier) then
        shouldRunAuto = false
        Questie:Debug(Questie.DEBUG_DEVELOP, "Modifier-Key down: Disabling QuestieAuto for now")
        return
    end

    -- We really want to disable this in instances, mostly to prevent retards from ruining groups.
    if (Questie.db.char.autoaccept and _QuestieAuto:IsAllowedNPC() and _QuestieAuto:IsAllowedQuest()) then
        Questie:Debug(Questie.DEBUG_DEVELOP, "INSIDE", event, ...)

        local questId = GetQuestID()
        ---@type Quest
        local quest = QuestieDB:GetQuest(questId)

        if quest == nil then
            Questie:Debug(Questie.DEBUG_DEVELOP, "quest == nil, retrying in 1 second")
            C_Timer.After(1, function ()
                questId = GetQuestID()
                ---@type Quest
                quest = QuestieDB:GetQuest(questId)
                if quest == nil then
                    Questie:Debug(Questie.DEBUG_DEVELOP, "retry failed. Quest", questId, "might not be in the DB!")
                else
                    _AutoAcceptQuest(questId, quest)
                end
            end)
            return
        end

        _AutoAcceptQuest(questId, quest)
    end
end

-- I was forced to make decision on offhand, cloak and shields separate from armor but I can't pick up my mind about the reason...
function QuestieAuto:QUEST_COMPLETE(event, ...)
    Questie:Debug(Questie.DEBUG_DEVELOP, "[EVENT] QUEST_COMPLETE", event, ...)
    lastEvent = "QUEST_COMPLETE"
    doneTalking = false

    if (not shouldRunAuto) then
        return
    elseif _QuestieAuto:IsBindTrue(Questie.db.char.autoModifier) then
        shouldRunAuto = false
        Questie:Debug(Questie.DEBUG_DEVELOP, "Modifier-Key down: Disabling QuestieAuto for now")
        return
    end

    -- blasted Lands citadel wonderful NPC. They do not trigger any events except quest_complete.
    -- if not AllowedToHandle() then
    --    return
    -- end
    if (Questie.db.char.autocomplete) then

        local questname = GetTitleText()
        local numOptions = GetNumQuestChoices()
        local questId = GetQuestID()
        Questie:Debug(Questie.DEBUG_DEVELOP, event, questname, numOptions, questId, ...)

        if numOptions > 1 then
            Questie:Debug(Questie.DEBUG_INFO, "Multiple rewards (" .. numOptions .. ")! Please choose appropriate reward!")
            return
        end

        -- A second reward panel for the quest we just turned in ourselves is a
        -- duplicate offer. Calling GetQuestReward again is a no-op server side,
        -- which is exactly what leaves the "Complete Quest" window stuck on
        -- screen. Close it instead of re-sending the turn-in.
        --
        -- Both tests deliberately require that this is the quest WE auto-turned
        -- in, so a reward panel we have never acted on can never be closed by
        -- mistake: the quest having left the log proves the turn-in landed, and
        -- the time window covers the duplicate that beats the log refresh.
        if questId > 0 and questId == lastTurnedInQuestId
            and ((not _IsQuestInLog(questId))
                or (GetTime() - lastTurnInTime) < QUEST_TURN_IN_THROTTLE) then
            Questie:Debug(Questie.DEBUG_DEVELOP, "Quest", questId, "is already turned in - closing stale reward frame")
            _CloseQuestFrame()
            return
        end

        -- Only record the turn-in if one was actually sent; TurnInQuest declines
        -- to act for disallowed NPCs/quests, and treating that as "turned in"
        -- would let the guard above close a window we intentionally left open.
        local didTurnIn = _QuestieAuto:TurnInQuest(1)
        if not didTurnIn then
            Questie:Debug(Questie.DEBUG_DEVELOP, "Turn-in was not sent for quest", questId)
            return
        end

        lastTurnedInQuestId = questId
        lastTurnInTime = GetTime()
        Questie:Debug(Questie.DEBUG_DEVELOP, "Completed quest!")

        -- Safety net: if the turn-in went through but the reward panel is somehow
        -- still up for a quest we no longer have, it is stale no matter what
        -- produced it. Dismiss it rather than leaving the player with a dead
        -- window they have to close by hand. GetQuestID() reports 0 once the
        -- dialog is gone, so a normally-closed frame never reaches the close.
        if questId > 0 then
            C_Timer.After(1.2, function()
                if GetQuestID() == questId
                    and (not _IsQuestInLog(questId))
                    and QuestFrameRewardPanel and QuestFrameRewardPanel:IsVisible() then
                    Questie:Debug(Questie.DEBUG_DEVELOP, "Reward frame still open for turned-in quest", questId, "- closing it")
                    _CloseQuestFrame()
                end
            end)
        end
    end
end

local _QuestFinishedCallback = function()
    if _QuestieAuto:AllQuestWindowsClosed() then
        Questie:Debug(Questie.DEBUG_DEVELOP, "All quest windows closed! Resetting shouldRunAuto")
        _QuestieAuto:ResetModifier()
    end
end

function QuestieAuto:QUEST_FINISHED()
    Questie:Debug(Questie.DEBUG_DEVELOP, "[EVENT] QUEST_FINISHED")

    C_Timer.After(0.5, _QuestFinishedCallback)
end

function _QuestieAuto:AllQuestWindowsClosed()
    if GossipFrame and (not GossipFrame:IsVisible())
            and GossipFrameGreetingPanel and (not GossipFrameGreetingPanel:IsVisible())
            and QuestFrameGreetingPanel and (not QuestFrameGreetingPanel:IsVisible())
            and QuestFrameDetailPanel and (not QuestFrameDetailPanel:IsVisible())
            and QuestFrameProgressPanel and (not QuestFrameProgressPanel:IsVisible())
            and QuestFrameRewardPanel and (not QuestFrameRewardPanel:IsVisible()) then
        return true
    end
    return false
end

function _QuestieAuto:ResetModifier()
    shouldRunAuto = true
    lastEvent = nil
end

--- The closingCounter needs to reach 1 for QuestieAuto to reset
--- Whenever the gossip frame is closed this event is called once, HOWEVER
--- when totally stop talking to an NPC this event is called twice.
--- Another special case is: If you run away from the NPC the event is called
--- just once.
function QuestieAuto:GOSSIP_CLOSED()
    Questie:Debug(Questie.DEBUG_DEVELOP, "[EVENT] GOSSIP_CLOSED")
    lastEvent = "GOSSIP_CLOSED"

    if doneTalking then
        doneTalking = false
        Questie:Debug(Questie.DEBUG_DEVELOP, "We are done talking to an NPC! Resetting shouldRunAuto")
        shouldRunAuto = true
        lastEvent = nil
    else
        doneTalking = true
    end
end
