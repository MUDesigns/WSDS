// WitchspireCoopOverhaul - shared settings, player keys and the saved coop manager.
//
// Settings come from ServerConfig.json -> "Coop" (the launcher passes them as -WSCoop_<Key>=<Value>).
// Without arguments (e.g. a normal listen host that has the mod installed) the defaults below apply.
// All gameplay decisions are made on the server.

namespace WSCoop
{
    FString Raw(const FString& Key)
    {
        FString Value;
        if (System::ParseParamValue(System::GetCommandLine(), f"WSCoop_{Key}=", Value))
            return Value;
        return "";
    }

    bool Flag(const FString& Key, bool Default)
    {
        const FString V = Raw(Key).ToLower();
        if (V.IsEmpty())
            return Default;
        return V == "true" || V == "1" || V == "yes";
    }

    float Number(const FString& Key, float Default)
    {
        const FString V = Raw(Key);
        if (V.IsEmpty())
            return Default;
        return float(String::Conv_StringToDouble(V));
    }

    bool InstancedLoot() { return Flag("InstancedLoot", true); }
    bool InstancedHarvest() { return Flag("InstancedHarvest", true); }
    float InstancedLootRange() { return Number("InstancedLootRange", 6000); }
    bool SharedObjectives() { return Flag("SharedObjectives", true); }
    bool RetroactiveMilestones() { return Flag("RetroactiveMilestones", true); }
    bool CatchUpXP() { return Flag("CatchUpXP", true); }
    float CatchUpMaxMultiplier() { return Number("CatchUpMaxMultiplier", 2.5); }
    float CatchUpPerLevel() { return Number("CatchUpPerLevel", 0.15); }
    bool CovenSynergy() { return Flag("CovenSynergy", true); }
    float CovenRange() { return Number("CovenRange", 5000); }
    float CovenBonusPerMember() { return Number("CovenBonusPerMember", 0.1); }

    void Info(const FString& Message)
    {
        Log(n"WSCoop", f"[WSCoop] {Message}");
    }

    // Stable per-player key: the same identity the save system uses for this player's character file.
    FString PlayerKey(const APlayerCharacter Player)
    {
        if (Player == nullptr)
            return "";
        APlayerController PC = Cast<APlayerController>(Player.Controller);
        if (PC == nullptr)
            return "";

        USaveSubsystem SaveSubsystem = USaveSubsystem::Get();
        if (SaveSubsystem != nullptr)
        {
            const TMap<const APlayerController, FSaveSystemIdentity>& Identities = SaveSubsystem.GetOnlineIdentities();
            if (Identities.Contains(PC))
            {
                const FSaveSystemIdentity& Identity = Identities[PC];
                if (!Identity.Steam.IsEmpty())
                    return Identity.Steam;
                if (!Identity.Epic.IsEmpty())
                    return Identity.Epic;
            }
        }
        if (PC.PlayerState != nullptr)
            return f"{PC.PlayerState.GetUniqueId().ToString().GetHash()}";
        return "";
    }

    FString PlayerName(const APlayerCharacter Player)
    {
        if (Player == nullptr || Player.PlayerState == nullptr)
            return "?";
        return Player.PlayerState.GetPlayerName();
    }

    // Notices travel as one string: "Title\nText" (a message without a line break gets the default title).
    const FString DefaultNoticeTitle = "Co-op";

    FString NoticeString(const FString& Title, const FString& Text)
    {
        return Title.IsEmpty() ? Text : f"{Title}\n{Text}";
    }

    // Shows a notice on this machine's screen, in the game's on-screen message banner with its own title.
    void ShowLocalNotice(const FString& Title, const FString& Text)
    {
        AOnScreenMessageManager Manager = Cast<AOnScreenMessageManager>(AGameManager::Get(AOnScreenMessageManager));
        if (Manager == nullptr)
            return;
        FOnScreenMessageRequest Request;
        Request.MessageType = EScreenMessageType::QuestUpdate;
        FWSNoticePayload Payload;
        Payload.Title = FText::FromString(Title.IsEmpty() ? DefaultNoticeTitle : Title);
        Payload.Info = FText::FromString(Text);
        Request.Payload.InitializeAs(Payload);
        Manager.LocalShowOnScreenMessage(Request);
        Info(f"Notice shown: {Title} | {Text}");
    }

    // Accepts "Title\nText" or plain text.
    void ShowLocalMessage(const FText& Message)
    {
        const FString Full = Message.ToString();
        FString Title;
        FString Text;
        if (Full.Split("\n", Title, Text))
            ShowLocalNotice(Title, Text);
        else
            ShowLocalNotice(DefaultNoticeTitle, Full);
    }

    // Server: show a notice to one player only.
    void Notify(const APlayerCharacter Player, const FString& Message, const FString& Title)
    {
        Notify(Player, NoticeString(Title, Message));
    }

    void Notify(const APlayerCharacter Player, const FString& Message)
    {
        if (Player == nullptr)
            return;
        APlayerController PC = Cast<APlayerController>(Player.Controller);
        if (PC == nullptr)
            return;
        if (PC.IsLocalController())
        {
            ShowLocalMessage(FText::FromString(Message));
            return;
        }
        UWSIdentityComponent Channel = WSIdentity::GetComponent(PC);
        if (Channel != nullptr)
            Channel.ClientCoopMessage(Message);
    }

    // All living player characters in the world.
    TArray<APlayerCharacter> GetPlayers()
    {
        TArray<APlayerCharacter> Result;
        AGameStateBase GameState = Gameplay::GetGameState();
        if (GameState == nullptr)
            return Result;
        for (APlayerState PS : GameState.PlayerArray)
        {
            if (PS == nullptr)
                continue;
            APlayerCharacter Character = Cast<APlayerCharacter>(PS.GetPawn());
            if (Character != nullptr)
                Result.Add(Character);
        }
        return Result;
    }

    AWSCoopManager GetManager()
    {
        return Cast<AWSCoopManager>(AGameManager::Get(AWSCoopManager));
    }

    float TimeOffsetHours()
    {
        AWSCoopManager Manager = GetManager();
        return Manager != nullptr ? Manager.TimeOffsetHours : 0.0;
    }
}

// A loot pickup dropped for one player only (see WSCoopLoot::DropPersonalLoot).
USTRUCT()
struct FWSCoopPersonalPickup
{
    UPROPERTY()
    AItemPickup Pickup;

    UPROPERTY()
    APlayerState Owner;
};

// World-saved coop state. Lives in the world save so it follows the server, not any single player.
UCLASS()
class AWSCoopManager : AGameManager
{
    default bReplicates = true;
    default bAlwaysRelevant = true;
    default bSupportsSaving = true;
    default bSupportsDirtying = true;

    // Personal loot pickups in the world and whose they are. Replicated so every game can hide the ones
    // that belong to someone else (kept out of AItemPickup: changing that class breaks its cooked Blueprints).
    UPROPERTY(Replicated, Transient, ReplicatedUsing = OnRep_PersonalPickups)
    TArray<FWSCoopPersonalPickup> PersonalPickups;

    UFUNCTION()
    void OnRep_PersonalPickups()
    {
        for (const FWSCoopPersonalPickup& Entry : PersonalPickups)
            WSCoopLoot::ApplyPersonalPickup(Entry.Pickup);
    }

    void AddPersonalPickup(AItemPickup Pickup, APlayerState PickupOwner)
    {
        FWSCoopPersonalPickup Entry;
        Entry.Pickup = Pickup;
        Entry.Owner = PickupOwner;
        PersonalPickups.Add(Entry);
        ForceNetUpdate();
    }

    // Owner of a personal pickup; nullptr for ordinary pickups.
    APlayerState PersonalOwnerOf(const AActor Pickup) const
    {
        if (Pickup == nullptr)
            return nullptr;
        for (const FWSCoopPersonalPickup& Entry : PersonalPickups)
        {
            if (Entry.Pickup == Pickup)
                return Entry.Owner;
        }
        return nullptr;
    }

    bool IsPersonalPickup(const AActor Pickup) const
    {
        if (Pickup == nullptr)
            return false;
        for (const FWSCoopPersonalPickup& Entry : PersonalPickups)
        {
            if (Entry.Pickup == Pickup)
                return true;
        }
        return false;
    }

    // Server: forget pickups that were collected or timed out.
    void PrunePersonalPickups()
    {
        int Removed = 0;
        for (int i = PersonalPickups.Num() - 1; i >= 0; --i)
        {
            if (!IsValid(PersonalPickups[i].Pickup))
            {
                PersonalPickups.RemoveAt(i);
                Removed++;
            }
        }
        if (Removed > 0)
            ForceNetUpdate();
    }

    // Admin time-of-day adjustment in hours, added to the game's world clock (replicated to clients).
    UPROPERTY(SaveGame, Replicated)
    float TimeOffsetHours = 0;

    void SetTimeOffset(float Hours)
    {
        TimeOffsetHours = Hours;
        MarkSaveGameDirty();
    }

    // "<chest>|<playerKey>" entries: which player already took their loot from which container.
    UPROPERTY(SaveGame)
    private TArray<FString> LootRecords;

    // Objective tags completed by anyone in this world (for shared / retroactive progression).
    UPROPERTY(SaveGame)
    TArray<FGameplayTag> WorldCompletedObjectives;

    // "<objectiveTag>|<playerKey>": completion effects already applied for that player.
    UPROPERTY(SaveGame)
    private TArray<FString> EffectRecords;

    private TSet<FString> LootLookup;

    // Per-player harvesting: "<harvestable>|<playerKey>|<unix time it regrows for them; 0 = never>".
    UPROPERTY(SaveGame)
    private TArray<FString> HarvestRecords;

    // "<harvestable>|<playerKey>" -> index into HarvestRecords (rebuilt on load).
    private TMap<FString, int> HarvestLookup;

    // Live map (wsdsmaps.com): every player who has played here, "<playerKey>|<lastSeenUnix>|<name>".
    UPROPERTY(SaveGame)
    private TArray<FString> PlayerRegistry;

    // Live map: each player's quest log as of their last save, "<playerKey>|<asOfUnix>|<questsJson>"
    // (a player's objectives only exist in memory while they are online).
    UPROPERTY(SaveGame)
    private TArray<FString> QuestCache;

    // Bed spawn points (see WSBedSpawn): "<playerKey>|<bedX>|<bedY>|<bedZ>|<wakeX>|<wakeY>|<wakeZ>|<yaw>".
    UPROPERTY(SaveGame)
    private TArray<FString> BedSpawns;

    private int FindBedSpawn(const FString& Key) const
    {
        const FString Prefix = f"{Key}|";
        for (int i = 0; i < BedSpawns.Num(); ++i)
        {
            if (BedSpawns[i].StartsWith(Prefix))
                return i;
        }
        return -1;
    }

    void SetBedSpawn(const FString& Key, const FVector& Bed, const FVector& Wake, float Yaw)
    {
        if (Key.IsEmpty())
            return;
        const FString Entry = f"{Key}|{Bed.X:.1f}|{Bed.Y:.1f}|{Bed.Z:.1f}|{Wake.X:.1f}|{Wake.Y:.1f}|{Wake.Z:.1f}|{Yaw:.1f}";
        const int Index = FindBedSpawn(Key);
        if (Index >= 0)
            BedSpawns[Index] = Entry;
        else
            BedSpawns.Add(Entry);
        MarkSaveGameDirty();
    }

    bool GetBedSpawn(const FString& Key, FVector& OutBed, FVector& OutWake, float& OutYaw) const
    {
        const int Index = FindBedSpawn(Key);
        if (Index < 0)
            return false;
        TArray<FString> F;
        BedSpawns[Index].ParseIntoArray(F, "|", false);
        if (F.Num() != 8)
            return false;
        OutBed = FVector(String::Conv_StringToDouble(F[1]), String::Conv_StringToDouble(F[2]), String::Conv_StringToDouble(F[3]));
        OutWake = FVector(String::Conv_StringToDouble(F[4]), String::Conv_StringToDouble(F[5]), String::Conv_StringToDouble(F[6]));
        OutYaw = float(String::Conv_StringToDouble(F[7]));
        return true;
    }

    bool HasBedSpawnAt(const FString& Key, const FVector& Bed) const
    {
        FVector B;
        FVector W;
        float Y = 0;
        return GetBedSpawn(Key, B, W, Y) && B.Distance(Bed) < 30.0;
    }

    void ClearBedSpawn(const FString& Key)
    {
        const int Index = FindBedSpawn(Key);
        if (Index < 0)
            return;
        BedSpawns.RemoveAt(Index);
        MarkSaveGameDirty();
    }

    // Forgets every spawn point on the bed at that spot; returns whose they were.
    TArray<FString> ClearBedSpawnsAt(const FVector& Bed)
    {
        TArray<FString> Keys;
        for (int i = BedSpawns.Num() - 1; i >= 0; --i)
        {
            TArray<FString> F;
            BedSpawns[i].ParseIntoArray(F, "|", false);
            if (F.Num() != 8)
                continue;
            const FVector B(String::Conv_StringToDouble(F[1]), String::Conv_StringToDouble(F[2]), String::Conv_StringToDouble(F[3]));
            if (B.Distance(Bed) < 30.0)
            {
                Keys.Add(F[0]);
                BedSpawns.RemoveAt(i);
            }
        }
        if (Keys.Num() > 0)
            MarkSaveGameDirty();
        return Keys;
    }

    // Map markers (see WSMapMarkers): "key|name|x|y|z|type|id" (entries from 0.0.49 have no type/id: a "meet"
    // marker with id 0). Replicated to every game and saved with the world.
    UPROPERTY(Replicated, SaveGame)
    TArray<FString> MapMarkers;

    // Where players went down, or the grave holding the items they dropped: "key|name|x|y|z|state" (state "down"
    // or "items"). Saved, so a grave marker survives a restart.
    UPROPERTY(Replicated, SaveGame)
    TArray<FString> DeathMarkers;

    // Short-lived pings (middle mouse): "key|name|x|y|z|label|id". Not saved.
    UPROPERTY(Replicated, Transient)
    TArray<FString> Pings;

    // Online players for the player list (hold P): "name|level|hp|maxhp|state". Not saved.
    UPROPERTY(Replicated, Transient)
    TArray<FString> PlayerInfos;

    // Bumped every time the night is slept away; each game fades its screen (see WSSleep).
    UPROPERTY(Replicated, Transient, ReplicatedUsing = OnRep_NightSkips)
    int NightSkips = 0;

    UFUNCTION()
    void OnRep_NightSkips()
    {
        WSSleep::OnNightSkippedLocal();
    }

    // The server's mod version (see WSVersion).
    UPROPERTY(Replicated, Transient)
    FString ServerModVersion;

    // Which features this server has turned on (Coop settings), for the games' UI.
    UPROPERTY(Replicated, Transient)
    bool bMapMarkersEnabled = false;

    UPROPERTY(Replicated, Transient)
    bool bQuickStackEnabled = false;

    UPROPERTY(Replicated, Transient)
    int MaxMarkersPerPlayer = 3;

    UPROPERTY(Replicated, Transient)
    bool bWeaponRerollEnabled = false;

    UPROPERTY(Replicated, Transient)
    bool bFamiliarSalvageEnabled = false;

    // ---- map markers ----

    // Index of a player's marker with that id, -1 if none.
    int FindMapMarker(const FString& Key, int Id) const
    {
        for (int i = 0; i < MapMarkers.Num(); ++i)
        {
            FString EntryKey;
            FString EntryName;
            FVector Location;
            FString Type;
            int EntryId = 0;
            if (WSMapMarkers::ParseMarker(MapMarkers[i], EntryKey, EntryName, Location, Type, EntryId) && EntryKey == Key && EntryId == Id)
                return i;
        }
        return -1;
    }

    // A player's markers, oldest first.
    TArray<int> MarkersOf(const FString& Key) const
    {
        TArray<int> Out;
        for (int i = 0; i < MapMarkers.Num(); ++i)
        {
            if (MapMarkers[i].StartsWith(f"{Key}|"))
                Out.Add(i);
        }
        return Out;
    }

    // Adds a marker; when the player already has MaxPerPlayer, their oldest goes. Returns the new id.
    int AddMapMarker(const FString& Key, const FString& OwnerName, const FVector& Location, const FString& Type, int MaxPerPlayer)
    {
        if (Key.IsEmpty())
            return -1;
        TArray<int> Mine = MarkersOf(Key);
        int NextId = 1;
        for (int Index : Mine)
        {
            FString EntryKey;
            FString EntryName;
            FVector L;
            FString T;
            int Id = 0;
            if (WSMapMarkers::ParseMarker(MapMarkers[Index], EntryKey, EntryName, L, T, Id))
                NextId = Math::Max(NextId, Id + 1);
        }
        while (Mine.Num() >= Math::Max(1, MaxPerPlayer))
        {
            MapMarkers.RemoveAt(Mine[0]);
            Mine = MarkersOf(Key);
        }
        const FString CleanName = OwnerName.Replace("|", "/").Left(64);
        MapMarkers.Add(f"{Key}|{CleanName}|{Location.X:.0f}|{Location.Y:.0f}|{Location.Z:.0f}|{Type}|{NextId}");
        MarkSaveGameDirty();
        return NextId;
    }

    bool RemoveMapMarker(const FString& Key, int Id)
    {
        const int Index = FindMapMarker(Key, Id);
        if (Index < 0)
            return false;
        MapMarkers.RemoveAt(Index);
        MarkSaveGameDirty();
        return true;
    }

    // ---- death markers ----

    int FindDeathMarker(const FString& Key) const
    {
        for (int i = 0; i < DeathMarkers.Num(); ++i)
        {
            if (DeathMarkers[i].StartsWith(f"{Key}|"))
                return i;
        }
        return -1;
    }

    void SetDeathMarker(const FString& Key, const FString& OwnerName, const FVector& Location, const FString& State)
    {
        if (Key.IsEmpty())
            return;
        const FString CleanName = OwnerName.Replace("|", "/").Left(64);
        const FString Entry = f"{Key}|{CleanName}|{Location.X:.0f}|{Location.Y:.0f}|{Location.Z:.0f}|{State}";
        const int Index = FindDeathMarker(Key);
        if (Index >= 0)
            DeathMarkers[Index] = Entry;
        else
            DeathMarkers.Add(Entry);
        MarkSaveGameDirty();
    }

    bool ClearDeathMarker(const FString& Key)
    {
        const int Index = FindDeathMarker(Key);
        if (Index < 0)
            return false;
        DeathMarkers.RemoveAt(Index);
        MarkSaveGameDirty();
        return true;
    }

    void NotePlayer(const FString& Key, const FString& PlayerName, int64 NowUnix)
    {
        if (Key.IsEmpty())
            return;
        const FString Prefix = f"{Key}|";
        for (int i = 0; i < PlayerRegistry.Num(); ++i)
        {
            if (!PlayerRegistry[i].StartsWith(Prefix))
                continue;
            TArray<FString> Fields;
            PlayerRegistry[i].ParseIntoArray(Fields, "|", false);
            const int64 Seen = Fields.Num() >= 2 ? String::Conv_StringToInt64(Fields[1]) : 0;
            const FString OldName = Fields.Num() >= 3 ? PlayerRegistry[i].RightChop(Fields[0].Len() + Fields[1].Len() + 2) : "";
            if (OldName == PlayerName && NowUnix - Seen < 60)
                return;
            PlayerRegistry[i] = f"{Key}|{NowUnix}|{PlayerName}";
            MarkSaveGameDirty();
            return;
        }
        PlayerRegistry.Add(f"{Key}|{NowUnix}|{PlayerName}");
        MarkSaveGameDirty();
    }

    // Registered players as parallel arrays.
    void GetRegisteredPlayers(TArray<FString>& OutKeys, TArray<FString>& OutNames, TArray<int64>& OutLastSeen) const
    {
        for (const FString& Entry : PlayerRegistry)
        {
            TArray<FString> Fields;
            Entry.ParseIntoArray(Fields, "|", false);
            if (Fields.Num() < 3)
                continue;
            OutKeys.Add(Fields[0]);
            OutLastSeen.Add(String::Conv_StringToInt64(Fields[1]));
            OutNames.Add(Entry.RightChop(Fields[0].Len() + Fields[1].Len() + 2));
        }
    }

    void SetQuestCache(const FString& Key, const FString& QuestsJson, int64 NowUnix)
    {
        if (Key.IsEmpty())
            return;
        const FString Entry = f"{Key}|{NowUnix}|{QuestsJson}";
        const FString Prefix = f"{Key}|";
        for (int i = 0; i < QuestCache.Num(); ++i)
        {
            if (QuestCache[i].StartsWith(Prefix))
            {
                QuestCache[i] = Entry;
                MarkSaveGameDirty();
                return;
            }
        }
        QuestCache.Add(Entry);
        MarkSaveGameDirty();
    }

    bool GetQuestCache(const FString& Key, FString& OutJson, int64& OutAsOf) const
    {
        const FString Prefix = f"{Key}|";
        for (const FString& Entry : QuestCache)
        {
            if (!Entry.StartsWith(Prefix))
                continue;
            const FString Rest = Entry.RightChop(Prefix.Len());
            const int Bar = Rest.Find("|");
            if (Bar < 0)
                return false;
            OutAsOf = String::Conv_StringToInt64(Rest.Left(Bar));
            OutJson = Rest.RightChop(Bar + 1);
            return true;
        }
        return false;
    }

    // Containers this player has looted (instanced loot records).
    TArray<FString> GetLootedContainers(const FString& PlayerKey) const
    {
        TArray<FString> Out;
        const FString Suffix = f"|{PlayerKey}";
        for (const FString& Record : LootRecords)
        {
            if (Record.EndsWith(Suffix))
                Out.Add(Record.Left(Record.Len() - Suffix.Len()));
        }
        return Out;
    }

    // This player's harvest records whose node name contains Filter, as "<node>|<regrowsAtUnix; 0 = never>".
    TArray<FString> GetHarvestEntries(const FString& PlayerKey, const FString& Filter) const
    {
        TArray<FString> Out;
        const FString Part = f"|{PlayerKey}|";
        for (const FString& Record : HarvestRecords)
        {
            if (!Record.Contains(Part) || !Record.Contains(Filter))
                continue;
            TArray<FString> Fields;
            Record.ParseIntoArray(Fields, "|");
            if (Fields.Num() == 3 && Fields[1] == PlayerKey)
                Out.Add(f"{Fields[0]}|{Fields[2]}");
        }
        return Out;
    }

    private void RebuildHarvestLookup()
    {
        HarvestLookup.Empty();
        for (int i = 0; i < HarvestRecords.Num(); ++i)
        {
            TArray<FString> Fields;
            HarvestRecords[i].ParseIntoArray(Fields, "|");
            if (Fields.Num() == 3)
                HarvestLookup.Add(f"{Fields[0]}|{Fields[1]}", i);
        }
    }

    // True while this player's harvest of that node has not regrown yet.
    bool HasHarvested(const FString& Harvestable, const FString& PlayerKey, int64 NowUnix)
    {
        if (HarvestLookup.Num() == 0 && HarvestRecords.Num() > 0)
            RebuildHarvestLookup();
        int Index = -1;
        if (!HarvestLookup.Find(f"{Harvestable}|{PlayerKey}", Index) || !HarvestRecords.IsValidIndex(Index))
            return false;
        TArray<FString> Fields;
        HarvestRecords[Index].ParseIntoArray(Fields, "|");
        if (Fields.Num() != 3)
            return false;
        const int64 Until = String::Conv_StringToInt64(Fields[2]);
        return Until == 0 || NowUnix < Until;
    }

    void MarkHarvested(const FString& Harvestable, const FString& PlayerKey, int64 UntilUnix)
    {
        if (PlayerKey.IsEmpty())
            return;
        if (HarvestLookup.Num() == 0 && HarvestRecords.Num() > 0)
            RebuildHarvestLookup();
        const FString Entry = f"{Harvestable}|{PlayerKey}|{UntilUnix}";
        int Index = -1;
        if (HarvestLookup.Find(f"{Harvestable}|{PlayerKey}", Index) && HarvestRecords.IsValidIndex(Index))
            HarvestRecords[Index] = Entry;
        else
        {
            HarvestRecords.Add(Entry);
            HarvestLookup.Add(f"{Harvestable}|{PlayerKey}", HarvestRecords.Num() - 1);
        }
        MarkSaveGameDirty();
    }

    int HarvestRecordCount() const
    {
        return HarvestRecords.Num();
    }

    // Tests: makes all of a player's regrowing harvests come back at UntilUnix.
    int SetRegrowTimes(const FString& PlayerKey, int64 UntilUnix)
    {
        int Changed = 0;
        for (int i = 0; i < HarvestRecords.Num(); ++i)
        {
            TArray<FString> Fields;
            HarvestRecords[i].ParseIntoArray(Fields, "|");
            if (Fields.Num() != 3 || Fields[1] != PlayerKey || Fields[2] == "0")
                continue;
            HarvestRecords[i] = f"{Fields[0]}|{Fields[1]}|{UntilUnix}";
            Changed++;
        }
        MarkSaveGameDirty();
        return Changed;
    }

    // Everything one player has taken that their game should keep hidden: gathered nodes that have not
    // regrown for them yet and looted chests. OutUntil: unix time it comes back for them, 0 = never.
    void GetTakenBy(const FString& PlayerKey, int64 NowUnix, TArray<FString>& OutNames, TArray<int64>& OutUntil) const
    {
        const FString HarvestPart = f"|{PlayerKey}|";
        for (const FString& Record : HarvestRecords)
        {
            if (!Record.Contains(HarvestPart))
                continue;
            TArray<FString> Fields;
            Record.ParseIntoArray(Fields, "|");
            if (Fields.Num() != 3 || Fields[1] != PlayerKey)
                continue;
            const int64 Until = String::Conv_StringToInt64(Fields[2]);
            if (Until != 0 && Until <= NowUnix)
                continue;
            OutNames.Add(Fields[0]);
            OutUntil.Add(Until);
        }
        const FString LootSuffix = f"|{PlayerKey}";
        for (const FString& Record : LootRecords)
        {
            if (!Record.EndsWith(LootSuffix))
                continue;
            OutNames.Add(Record.Left(Record.Len() - LootSuffix.Len()));
            OutUntil.Add(0);
        }
    }

    // Admin / tests: forget everything recorded for one player (chests looted, nodes harvested).
    int ForgetPlayerLoot(const FString& PlayerKey)
    {
        int Removed = 0;
        const FString LootSuffix = f"|{PlayerKey}";
        for (int i = LootRecords.Num() - 1; i >= 0; --i)
        {
            if (LootRecords[i].EndsWith(LootSuffix))
            {
                LootRecords.RemoveAt(i);
                Removed++;
            }
        }
        const FString HarvestPart = f"|{PlayerKey}|";
        for (int i = HarvestRecords.Num() - 1; i >= 0; --i)
        {
            if (HarvestRecords[i].Contains(HarvestPart))
            {
                HarvestRecords.RemoveAt(i);
                Removed++;
            }
        }
        RebuildLookup();
        RebuildHarvestLookup();
        MarkSaveGameDirty();
        return Removed;
    }

    // Transient quest-sharing state (see WSCoopQuests).
    FGameplayTag CurrentCompletionTag;
    bool bPropagating = false;

    bool HasEffectsApplied(FGameplayTag Tag, const FString& PlayerKey) const
    {
        return EffectRecords.Contains(f"{Tag}|{PlayerKey}");
    }

    void MarkEffectsApplied(FGameplayTag Tag, const FString& PlayerKey)
    {
        if (PlayerKey.IsEmpty())
            return;
        const FString Entry = f"{Tag}|{PlayerKey}";
        if (EffectRecords.Contains(Entry))
            return;
        EffectRecords.Add(Entry);
        MarkSaveGameDirty();
    }

    // Players whose character save has been applied (catch-up must wait for this).
    private TSet<APlayerController> LoadedPlayers;

    bool IsPlayerLoaded(const APlayerController PC) const
    {
        return PC != nullptr && LoadedPlayers.Contains(PC);
    }

    UFUNCTION()
    private void OnPlayerLoaded(APlayerController Player, bool bSuccess)
    {
        if (Player == nullptr)
            return;
        LoadedPlayers.Add(Player);
        APlayerCharacter Character = Cast<APlayerCharacter>(Player.GetControlledPawn());
        WSCoop::Info(f"Character data ready for {Player.PlayerState.GetPlayerName()} (fromSave={bSuccess})");
        if (Character != nullptr)
            WSCoopQuests::CatchUp(Character);
    }

    UFUNCTION(BlueprintOverride)
    void BeginPlay()
    {
        if (HasAuthority())
        {
            USaveSubsystem SaveSubsystem = USaveSubsystem::Get();
            if (SaveSubsystem != nullptr)
                SaveSubsystem.OnPlayerLoaded.AddUFunction(this, n"OnPlayerLoaded");
        }
        RebuildLookup();
        WSCoop::Info(f"Coop manager ready (authority={HasAuthority()}) lootRecords={LootRecords.Num()} worldObjectives={WorldCompletedObjectives.Num()}");
    }

    UFUNCTION(BlueprintOverride)
    void ActorLoaded()
    {
        RebuildLookup();
        WSCoop::Info(f"Coop manager loaded from save: lootRecords={LootRecords.Num()} worldObjectives={WorldCompletedObjectives.Num()}");
    }

    private void RebuildLookup()
    {
        LootLookup.Empty();
        LootLookup.Append(LootRecords);
    }

    bool HasLooted(const FString& ContainerKey, const FString& PlayerKey) const
    {
        return LootLookup.Contains(f"{ContainerKey}|{PlayerKey}");
    }

    void MarkLooted(const FString& ContainerKey, const FString& PlayerKey)
    {
        const FString Entry = f"{ContainerKey}|{PlayerKey}";
        if (LootLookup.Contains(Entry))
            return;
        LootLookup.Add(Entry);
        LootRecords.Add(Entry);
        MarkSaveGameDirty();
    }

    int LootRecordCount() const
    {
        return LootRecords.Num();
    }

    int CountLooters(const FString& ContainerKey) const
    {
        int Count = 0;
        const FString Prefix = f"{ContainerKey}|";
        for (const FString& Entry : LootRecords)
        {
            if (Entry.StartsWith(Prefix))
                Count++;
        }
        return Count;
    }

    // Dungeon resets etc.: everyone may loot this container again.
    void ResetContainer(const FString& ContainerKey)
    {
        const FString Prefix = f"{ContainerKey}|";
        for (int i = LootRecords.Num() - 1; i >= 0; --i)
        {
            if (LootRecords[i].StartsWith(Prefix))
                LootRecords.RemoveAt(i);
        }
        RebuildLookup();
        MarkSaveGameDirty();
    }

    void AddWorldObjective(FGameplayTag Tag)
    {
        if (!Tag.IsValid() || WorldCompletedObjectives.Contains(Tag))
            return;
        WorldCompletedObjectives.Add(Tag);
        MarkSaveGameDirty();
    }
};

// Coop notice shown in the on-screen message banner (see UOnScreenMessageDisplay.SetupWidget).
USTRUCT()
struct FWSNoticePayload
{
    FText Title;
    FText Info;
};

// Remembers the quest banner's own title while coop notices borrow it (see UOnScreenMessageDisplay.SetupWidget).
UCLASS()
class UWSNoticeState : UScriptWorldSubsystem
{
    FText QuestTitle;
    bool bQuestTitleSaved = false;
};
