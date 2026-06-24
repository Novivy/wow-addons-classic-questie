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
        for index=1, #completeQuests, MOP_INDEX_COMPLETE do
            _QuestieAuto:CompleteQuestFromGossip(index, completeQuests, MOP_INDEX_COMPLETE)
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
    if questId == lastAcceptedQuestId and (GetTime() - lastAcceptTime) < QUEST_ACCEPT_THROTTLE then
        -- The quest was just accepted, but its detail frame got re-opened (e.g. the
        -- gossip/greeting list re-fired after a turn-in and re-selected it). Don't
        -- accept again; dismiss the stale window instead of leaving it open.
        Questie:Debug(Questie.DEBUG_DEVELOP, "Skipping duplicate auto-accept for quest", questId, "- closing stale detail frame")
        if CloseQuest then
            CloseQuest()
        end
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
    if(Questie.db.char.autoaccept) then
       ConfirmAcceptQuest()
    end
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
        for index = 1, GetNumActiveQuests() do
            local quest, isComplete = GetActiveTitle(index)
            Questie:Debug(Questie.DEBUG_DEVELOP, quest, isComplete)
            if isComplete then SelectActiveQuest(index) end
        end
    end

    if (Questie.db.char.autoaccept) then
        local availableQuestsCount = GetNumAvailableQuests()
        if lastIndexTried == 0 or lastIndexTried > availableQuestsCount then
            lastIndexTried = 1
        end
        Questie:Debug(Questie.DEBUG_DEVELOP, "lastIndex:", lastIndexTried)
        if availableQuestsCount > 0 and lastIndexTried < availableQuestsCount then
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
        Questie:Debug(Questie.DEBUG_DEVELOP, event, questname, numOptions, ...)

        if numOptions > 1 then
            Questie:Debug(Questie.DEBUG_INFO, "Multiple rewards (" .. numOptions .. ")! Please choose appropriate reward!")
        else
            _QuestieAuto:TurnInQuest(1)
            Questie:Debug(Questie.DEBUG_DEVELOP, "Completed quest!")
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
