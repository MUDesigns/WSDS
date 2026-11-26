// WitchspireDedicatedServer - live map data for wsdsmaps.com (read by the WSDS app from the log).
//
// While someone has the map open, WSDS renews a "watch lease" (admin command `mapwatch <seconds>`).
// Only during a lease does the server report player positions, 5 times per second:
//     [WSDS-POS] <unix ms>|<player key>,<x>,<y>,<z>,<yaw>;<player key>,...
// Without a lease this subsystem does no work at all.

UCLASS()
class UWSMapSubsystem : UScriptWorldSubsystem
{
    private float LeaseLeft = 0;
    private float PosAccumulator = 0;
    private bool bPermanentLease = false;
    private FString LastEntries = "-";
    private float SinceLastPos = 0;
    const float PosInterval = 0.2;

    UFUNCTION(BlueprintOverride)
    void OnWorldBeginPlay()
    {
        // Development only: keep the lease alive for lag measurements.
        bPermanentLease = System::IsServer() && WSDS::IsHeadlessHost()
            && System::ParseParam(System::GetCommandLine(), "WSTestMapWatch");
        // Keep each player's quest log for when they are offline (refreshed whenever they are saved).
        USaveSubsystem Saves = USaveSubsystem::Get();
        if (Saves != nullptr && System::IsServer() && WSDS::IsHeadlessHost())
            Saves.OnPlayerSaved.AddUFunction(this, n"OnPlayerSaved");
    }

    void Watch(float Seconds)
    {
        if (LeaseLeft <= 0)
            LastEntries = "-"; // a new viewer gets a position line right away
        LeaseLeft = Math::Clamp(Seconds, 1.0, 60.0);
    }

    UFUNCTION(BlueprintOverride)
    void Tick(float DeltaTime)
    {
        if (LeaseLeft <= 0 && !bPermanentLease)
            return;
        LeaseLeft -= DeltaTime;
        PosAccumulator += DeltaTime;
        if (PosAccumulator < PosInterval)
            return;
        PosAccumulator = Math::Fmod(PosAccumulator, PosInterval);
        EmitPositions();
    }

    // ---- Queries (answered as [WSDS-MAP] <reqId> <part>/<total> <json chunk>) ----

    void Answer(const FString& Cmd, const TArray<FString>& Args)
    {
        const FString ReqId = Args.Num() >= 2 ? Args[1] : "0";
        if (Cmd == "mapinfo")
            EmitChunked(ReqId, MapInfoJson());
        else if (Cmd == "mapplayers")
            EmitChunked(ReqId, PlayersJson());
        else if (Cmd == "mapprogress" && Args.Num() >= 3)
            EmitChunked(ReqId, ProgressJson(Args[2]));
        else if (Cmd == "maptestchunk")
        {
            // Test only: a 4-byte character straddling the first chunk boundary.
            FString S;
            for (int i = 0; i < 4089; i++) S += "a";
            S += "\U0001F600";
            for (int i = 0; i < 5000; i++) S += "b";
            EmitChunked(ReqId, f"{{\"s\":{WSAdmin::Json(S)}}}");
        }
        else if (Cmd == "maptestjson")
        {
            // Test only: control characters must come out as valid JSON on one log line.
            FString Weird = "line1\nline2\ttab \"quoted\" back\\slash ";
            Weird.AppendChar(1);
            Weird += " end";
            EmitChunked(ReqId, f"{{\"s\":{WSAdmin::Json(Weird)}}}");
        }
        else if (Cmd == "maptestquest" && Args.Num() >= 3)
            EmitChunked(ReqId, RevealFirstQuest(Args[2]));
        else
            EmitChunked(ReqId, "{\"error\":\"bad map query\"}");
    }

    void EmitChunked(const FString& ReqId, const FString& Json)
    {
        const int ChunkLen = 4096;
        TArray<FString> Chunks;
        int Start = 0;
        while (Start < Json.Len())
        {
            int End = Math::Min(Start + ChunkLen, Json.Len());
            // Never end a chunk between the two halves of a 4-byte character.
            if (End < Json.Len())
            {
                const int Code = int(Json[End - 1]) & 0xFFFF; // characters come back as signed 16-bit
                if (Code >= 0xD800 && Code <= 0xDBFF)
                    End--;
            }
            Chunks.Add(Json.Mid(Start, End - Start));
            Start = End;
        }
        if (Chunks.Num() == 0)
            Chunks.Add("{}");
        for (int i = 0; i < Chunks.Num(); i++)
            Log(n"WSDS", f"[WSDS-MAP] {ReqId} {i + 1}/{Chunks.Num()} {Chunks[i]}");
    }

    private FString JB(bool bValue) const
    {
        return bValue ? "true" : "false";
    }

    private int64 NowUnix() const
    {
        return FDateTime::UtcNow().ToUnixTimestamp();
    }

    // Online players by key (characters only, never the host's own controller).
    private TMap<FString, APlayerCharacter> OnlineCharacters()
    {
        TMap<FString, APlayerCharacter> Out;
        AGameStateBase GameState = Gameplay::GetGameState();
        if (GameState == nullptr)
            return Out;
        for (APlayerState PS : GameState.PlayerArray)
        {
            if (PS == nullptr)
                continue;
            APlayerController PC = PS.GetPlayerController();
            if (PC == nullptr || PC.IsLocalController())
                continue;
            APlayerCharacter P = Cast<APlayerCharacter>(PC.GetControlledPawn());
            const FString Key = WSAdmin::KeyOf(PC);
            if (P != nullptr && !Key.IsEmpty())
                Out.Add(Key, P);
        }
        return Out;
    }

    // Called with every state report (every 3 s): remembers who plays here and under which name.
    void NoteOnlinePlayers()
    {
        AWSCoopManager Manager = WSCoop::GetManager();
        if (Manager == nullptr)
            return;
        const int64 Now = NowUnix();
        TMap<FString, APlayerCharacter> Online = OnlineCharacters();
        for (auto It : Online)
            Manager.NotePlayer(It.Key, It.Value.PlayerState.GetPlayerName(), Now);
    }

    UFUNCTION()
    private void OnPlayerSaved(APlayerController Player, bool bSuccess)
    {
        if (Player == nullptr || Player.IsLocalController())
            return;
        APlayerCharacter P = Cast<APlayerCharacter>(Player.GetControlledPawn());
        AWSCoopManager Manager = WSCoop::GetManager();
        const FString Key = WSAdmin::KeyOf(Player);
        if (P == nullptr || Manager == nullptr || Key.IsEmpty())
            return;
        Manager.NotePlayer(Key, Player.PlayerState.GetPlayerName(), NowUnix());
        Manager.SetQuestCache(Key, QuestsJson(P), NowUnix());
    }

    private FString MapInfoJson()
    {
        FString UpperLeft = "[0,0]";
        FString LevelSize = "[0,0]";
        FString Landmarks;
        TArray<AWorldMap> Maps;
        GetAllActorsOfClass(Maps);
        AWorldMapManager MapManager = AGameManager::Get(AWorldMapManager);
        if (Maps.Num() > 0)
        {
            AWorldMap Map = Maps[0];
            UpperLeft = f"[{int(Map.UpperLeftBound.X)},{int(Map.UpperLeftBound.Y)}]";
            LevelSize = f"[{int(Map.LevelSize.X)},{int(Map.LevelSize.Y)}]";
            for (const FStaticWorldMapElement& Element : Map.StaticMapElements)
            {
                FString State = "Unknown";
                FRegisteredWorldMapElement Registered;
                if (MapManager != nullptr && MapManager.FindRegisteredElementById(Element.UniqueId, Registered))
                {
                    if (Registered.Info.Discovery.CurrentState == EWorldMapElementState::Discovered)
                        State = "Discovered";
                    else if (Registered.Info.Discovery.CurrentState == EWorldMapElementState::Undiscovered)
                        State = "Undiscovered";
                }
                Landmarks += (Landmarks.IsEmpty() ? "" : ",") + f"{WSAdmin::Json(Element.UniqueId.ToString())}:\"{State}\"";
            }
        }
        const FString WorldName = WSDS::Param("WSWorldName", USaveSubsystem::Get().GetSlotName());
        return f"{{\"name\":{WSAdmin::Json(WorldName)},\"upperLeft\":{UpperLeft},\"levelSize\":{LevelSize},\"instancedLoot\":{JB(WSCoop::InstancedLoot())},\"landmarks\":{{{Landmarks}}}}}";
    }

    private FString PlayersJson()
    {
        AWSCoopManager Manager = WSCoop::GetManager();
        TMap<FString, APlayerCharacter> Online = OnlineCharacters();
        TArray<FString> Keys;
        TArray<FString> Names;
        TArray<int64> Seen;
        if (Manager != nullptr)
            Manager.GetRegisteredPlayers(Keys, Names, Seen);
        FString Out;
        for (int i = 0; i < Keys.Num(); i++)
        {
            const bool bOnline = Online.Contains(Keys[i]);
            Out += (Out.IsEmpty() ? "" : ",") + f"{{\"key\":{WSAdmin::Json(Keys[i])},\"name\":{WSAdmin::Json(Names[i])},\"online\":{JB(bOnline)},\"lastSeen\":{Seen[i]}}}";
        }
        return f"{{\"players\":[{Out}],\"pillars\":[{PillarsJson()}]}}";
    }

    // Flight pillars ("flight towers") and their orbs: world state shared by everyone, so it rides along with
    // the player list. Orbs are [x, y, z, collected].
    private FString PillarsJson()
    {
        TArray<AFlightPillar> Pillars;
        GetAllActorsOfClass(Pillars);
        FString Out;
        for (AFlightPillar Pillar : Pillars)
        {
            if (!IsValid(Pillar))
                continue;
            FString Orbs;
            for (int i = 0; i < Pillar.Orbs.Num(); i++)
            {
                const FVector L = Pillar.ActorTransform.TransformPosition(Pillar.Orbs[i].Location);
                const int Collected = Pillar.ActivatedOrbs.IsValidIndex(i) && Pillar.ActivatedOrbs[i] ? 1 : 0;
                Orbs += (Orbs.IsEmpty() ? "" : ",") + f"[{int(L.X)},{int(L.Y)},{int(L.Z)},{Collected}]";
            }
            const FVector A = Pillar.ActorLocation;
            Out += (Out.IsEmpty() ? "" : ",")
                + f"{{\"id\":{WSAdmin::Json(Pillar.GetName().ToString())},\"name\":{WSAdmin::Json(Pillar.PillarName.ToString())},"
                + f"\"x\":{int(A.X)},\"y\":{int(A.Y)},\"z\":{int(A.Z)},\"dormant\":{JB(Pillar.bDormant)},"
                + f"\"active\":{JB(Pillar.IsActivated())},\"orbs\":[{Orbs}]}}";
        }
        return Out;
    }

    private FString ProgressJson(const FString& Key)
    {
        AWSCoopManager Manager = WSCoop::GetManager();
        if (Manager == nullptr)
            return "{\"error\":\"coop manager missing\"}";
        TArray<FString> Keys;
        TArray<FString> Names;
        TArray<int64> Seen;
        Manager.GetRegisteredPlayers(Keys, Names, Seen);
        const int Index = Keys.FindIndex(Key);
        if (Index < 0)
            return "{\"error\":\"unknown player\"}";

        FString Chests;
        for (const FString& Chest : Manager.GetLootedContainers(Key))
            Chests += (Chests.IsEmpty() ? "" : ",") + WSAdmin::Json(Chest);

        FString Satchels;
        for (const FString& Entry : Manager.GetHarvestEntries(Key, "Satchel"))
        {
            const int Bar = Entry.Find("|");
            Satchels += (Satchels.IsEmpty() ? "" : ",") + f"{{\"id\":{WSAdmin::Json(Entry.Left(Bar))},\"regrowsAt\":{Entry.RightChop(Bar + 1)}}}";
        }

        TMap<FString, APlayerCharacter> Online = OnlineCharacters();
        APlayerCharacter Live;
        const bool bOnline = Online.Find(Key, Live);
        FString Quests = "[]";
        int64 AsOf = 0;
        if (bOnline)
        {
            Quests = QuestsJson(Live);
            AsOf = NowUnix();
            Manager.SetQuestCache(Key, Quests, AsOf);
        }
        else if (!Manager.GetQuestCache(Key, Quests, AsOf))
        {
            Quests = "[]";
        }
        return f"{{\"key\":{WSAdmin::Json(Key)},\"name\":{WSAdmin::Json(Names[Index])},\"online\":{JB(bOnline)},\"chests\":[{Chests}],\"satchels\":[{Satchels}],\"quests\":{Quests},\"questsAsOf\":{AsOf}}}";
    }

    // Test only: reveals the first visible objective of the first quest for a player (by name), so a test
    // character that skipped the tutorial has something in its quest log.
    private FString RevealFirstQuest(const FString& PlayerName)
    {
        TMap<FString, APlayerCharacter> Online = OnlineCharacters();
        for (auto It : Online)
        {
            if (It.Value.PlayerState.GetPlayerName() != PlayerName || It.Value.ObjectiveComp == nullptr)
                continue;
            UObjectiveComponent Comp = It.Value.ObjectiveComp;
            for (auto Quest : Comp.Quests)
            {
                for (const FGameplayTag& Tag : Quest.Value.ObjectivesInQuest)
                {
                    UObjective Objective = Comp.GetObjectiveByTag(Tag);
                    if (Objective == nullptr || Objective.DisplayData.bHideInUI || Comp.IsObjectiveComplete(Tag))
                        continue;
                    Comp.ForceReveal(Tag);
                    return f"{{\"revealed\":{WSAdmin::Json(Tag.ToString())}}}";
                }
            }
        }
        return "{\"error\":\"nothing to reveal\"}";
    }

    // The player's quest log: revealed quests with their visible objectives.
    private FString QuestsJson(APlayerCharacter Player)
    {
        UObjectiveComponent Comp = Player != nullptr ? Player.ObjectiveComp : nullptr;
        if (Comp == nullptr)
            return "[]";
        // Like the game's quest log: revealed (active) and completed objectives, grouped by their quest.
        // IsObjectiveRevealed/IsObjectiveComplete also cover shared (global) objectives.
        TMap<FGameplayTag, FGameplayTag> QuestOfObjective;
        for (auto Quest : Comp.Quests)
        {
            for (const FGameplayTag& Tag : Quest.Value.ObjectivesInQuest)
                QuestOfObjective.Add(Tag, Quest.Key);
        }

        TArray<FGameplayTag> QuestOrder;
        TMap<FGameplayTag, FString> QuestObjectives;
        for (auto Entry : Comp.Objectives)
        {
            const FGameplayTag Tag = Entry.Key;
            UObjective Objective = Entry.Value;
            if (Objective == nullptr || Objective.DisplayData.bHideInUI)
                continue;
            FGameplayTag QuestTag;
            if (!QuestOfObjective.Find(Tag, QuestTag))
                continue;
            const bool bComplete = Comp.IsObjectiveComplete(Tag);
            if (!bComplete && !Comp.IsObjectiveRevealed(Tag))
                continue;
            const int Required = Math::Max(1, Comp.GetObjectiveRequiredAmount(Tag));
            const int Current = bComplete ? Required : Math::Max(0, Comp.GetObjectiveProgress(Tag));
            const FString Json = f"{{\"tag\":{WSAdmin::Json(Tag.ToString())},\"text\":{WSAdmin::Json(Objective.DisplayData.ObjectiveText.ToString())},\"current\":{Current},\"required\":{Required},\"complete\":{JB(bComplete)}}}";
            FString Existing;
            if (QuestObjectives.Find(QuestTag, Existing))
                QuestObjectives.Add(QuestTag, Existing + "," + Json);
            else
            {
                QuestOrder.Add(QuestTag);
                QuestObjectives.Add(QuestTag, Json);
            }
        }

        FString Out;
        for (const FGameplayTag& QuestTag : QuestOrder)
        {
            TOptional<FQuestDefinition> Quest = Comp.FindQuest(QuestTag);
            if (!Quest.IsSet())
                continue;
            const bool bQuestComplete = Comp.IsQuestIsComplete(QuestTag);
            Out += (Out.IsEmpty() ? "" : ",") + f"{{\"tag\":{WSAdmin::Json(QuestTag.ToString())},\"name\":{WSAdmin::Json(Quest.Value.QuestName.ToString())},\"category\":{WSAdmin::Json(Quest.Value.QuestCategory.ToString())},\"complete\":{JB(bQuestComplete)},\"objectives\":[{QuestObjectives[QuestTag]}]}}";
        }
        return f"[{Out}]";
    }

    private void EmitPositions()
    {
        AGameStateBase GameState = Gameplay::GetGameState();
        if (GameState == nullptr)
            return;
        FString Entries;
        for (APlayerState PS : GameState.PlayerArray)
        {
            if (PS == nullptr)
                continue;
            APlayerController PC = PS.GetPlayerController();
            if (PC == nullptr || PC.IsLocalController())
                continue;
            APawn Pawn = PC.GetControlledPawn();
            if (Pawn == nullptr)
                continue;
            const FString Key = WSAdmin::KeyOf(PC);
            if (Key.IsEmpty())
                continue;
            const FVector L = Pawn.GetActorLocation();
            const int Yaw = int(Math::Fmod(Pawn.GetActorRotation().Yaw + 360.0, 360.0)) % 360;
            Entries += (Entries.IsEmpty() ? "" : ";") + f"{Key},{int(L.X)},{int(L.Y)},{int(L.Z)},{Yaw}";
        }
        // Only when someone moved (or turned), plus a heartbeat every 5 s: standing players don't fill the log.
        SinceLastPos += PosInterval;
        if (Entries == LastEntries && SinceLastPos < 5.0)
            return;
        LastEntries = Entries;
        SinceLastPos = 0;
        const FDateTime Now = FDateTime::UtcNow();
        const int64 Ms = Now.ToUnixTimestamp() * 1000 + Now.GetMillisecond();
        Log(n"WSDS", f"[WSDS-POS] {Ms}|{Entries}");
    }
};
