// WitchspireDedicatedServer - admin command channel and commands.
//
// Transport: the WSDS app writes <ServerData>/Saved/WSDS/commands.txt and then creates commands.ready.
// The file sets console variables (script console *commands* are cheat-flagged and ignored by shipping
// builds; console *variables* are not), e.g.
//     wsds.c0 "kick Morgana Griefing"
//     wsds.c1 "give Haze Items.Resource.Wood 50"
//     wsds.count 2
// The server runs the file with UE's `exec` (synchronous) and dispatches the commands.
//
// Output for the app (structured log lines):
//     [WSDS-RESULT] {"ok":true,"cmd":"give","msg":"..."}
//     [WSDS-STATE]  {"uptime":..,"players":[{...}]}        (periodic)
//     [WSDS-ITEM]   <tag>|<display name>                     (catalogue, on "items")
//     [WSDS-EVENT]  {"type":"ban","key":"..","name":".."}    (things the app must persist)

namespace WSAdmin
{
    const FConsoleVariable Count("wsds.count", 0);
    const FConsoleVariable C0("wsds.c0", "");
    const FConsoleVariable C1("wsds.c1", "");
    const FConsoleVariable C2("wsds.c2", "");
    const FConsoleVariable C3("wsds.c3", "");
    const FConsoleVariable C4("wsds.c4", "");
    const FConsoleVariable C5("wsds.c5", "");
    const FConsoleVariable C6("wsds.c6", "");
    const FConsoleVariable C7("wsds.c7", "");
    const FConsoleVariable C8("wsds.c8", "");
    const FConsoleVariable C9("wsds.c9", "");
    const int MaxCommands = 10;

    FString Read(int Index)
    {
        switch (Index)
        {
            case 0: return C0.GetString();
            case 1: return C1.GetString();
            case 2: return C2.GetString();
            case 3: return C3.GetString();
            case 4: return C4.GetString();
            case 5: return C5.GetString();
            case 6: return C6.GetString();
            case 7: return C7.GetString();
            case 8: return C8.GetString();
            case 9: return C9.GetString();
        }
        return "";
    }

    // ---- helpers ----

    FString Json(const FString& Value)
    {
        FString Escaped = Value.Replace("\\", "\\\\").Replace("\"", "\\\"");
        // Control characters (newlines in names or quest texts, ...) would break the JSON and the log line.
        bool bHasControl = false;
        for (int i = 0; i < Escaped.Len() && !bHasControl; i++)
            bHasControl = (int(Escaped[i]) & 0xFFFF) < 0x20;
        if (bHasControl)
        {
            const FString HexDigits = "0123456789abcdef";
            FString Out;
            for (int i = 0; i < Escaped.Len(); i++)
            {
                const int Code = int(Escaped[i]) & 0xFFFF;
                if (Code < 0x20)
                    Out += "\\u00" + HexDigits.Mid(Code >> 4, 1) + HexDigits.Mid(Code & 15, 1);
                else
                    Out += Escaped.Mid(i, 1);
            }
            Escaped = Out;
        }
        return "\"" + Escaped + "\"";
    }

    void Result(bool bOk, const FString& Cmd, const FString& Message)
    {
        const FString OkText = bOk ? "true" : "false";
        Log(n"WSDS", f"[WSDS-RESULT] {{\"ok\":{OkText},\"cmd\":{Json(Cmd)},\"msg\":{Json(Message)}}}");
    }

    void Event(const FString& Type, const FString& Key, const FString& Name, const FString& Detail)
    {
        Log(n"WSDS", f"[WSDS-EVENT] {{\"type\":{Json(Type)},\"key\":{Json(Key)},\"name\":{Json(Name)},\"detail\":{Json(Detail)}}}");
    }

    // Splits a command line into words; "double quoted" words may contain spaces.
    TArray<FString> Tokenize(const FString& Line)
    {
        TArray<FString> Out;
        TArray<FString> Parts;
        Line.ParseIntoArray(Parts, "\"", false);
        // Even parts are outside quotes (split on spaces), odd parts are quoted words.
        for (int i = 0; i < Parts.Num(); i++)
        {
            if (i % 2 == 1)
            {
                Out.Add(Parts[i]);
                continue;
            }
            TArray<FString> Words;
            Parts[i].ParseIntoArray(Words, " ", true);
            Out.Append(Words);
        }
        return Out;
    }

    FString JoinFrom(const TArray<FString>& Args, int Start)
    {
        FString Text;
        for (int i = Start; i < Args.Num(); i++)
        {
            if (i > Start)
                Text += " ";
            Text += Args[i];
        }
        return Text;
    }

    APlayerCharacter FindPlayer(const FString& NameOrKey)
    {
        const FString Wanted = NameOrKey.ToLower();
        for (APlayerCharacter P : WSCoop::GetPlayers())
        {
            if (WSCoop::PlayerName(P).ToLower() == Wanted || WSCoop::PlayerKey(P) == NameOrKey)
                return P;
        }
        return nullptr;
    }

    // Teleports like the game's own waystones: the player sees a loading screen, the destination loads
    // first and the player is placed on safe ground near it. A plain teleport could drop them into a part
    // of the world the server has not loaded yet.
    bool AdminTeleport(APlayerCharacter P, const FVector& Dest, const FRotator& Rotation)
    {
        if (P.TeleportComp != nullptr)
        {
            FTeleportRequest Request = Teleport::AtFeet(Dest);
            Request.Rotation = Rotation;
            Request.bUseActorRotation = false;
            P.TeleportComp.Request(Request);
            return true;
        }
        return P.HercTeleportTo(Dest, Rotation, false, true);
    }

    APlayerController FindController(const FString& NameOrKey)
    {
        const FString Wanted = NameOrKey.ToLower();
        AGameStateBase GameState = Gameplay::GetGameState();
        if (GameState == nullptr)
            return nullptr;
        for (APlayerState PS : GameState.PlayerArray)
        {
            if (PS == nullptr)
                continue;
            APlayerController PC = PS.GetPlayerController();
            if (PC == nullptr || PC.IsLocalController())
                continue;
            if (PS.GetPlayerName().ToLower() == Wanted)
                return PC;
            APlayerCharacter Pawn = Cast<APlayerCharacter>(PS.GetPawn());
            if (Pawn != nullptr && WSCoop::PlayerKey(Pawn) == NameOrKey)
                return PC;
            if (WSIdentity::GetSaveName(PC) == NameOrKey)
                return PC;
        }
        return nullptr;
    }

    FString KeyOf(APlayerController PC)
    {
        if (PC == nullptr)
            return "";
        APlayerCharacter Pawn = Cast<APlayerCharacter>(PC.GetControlledPawn());
        if (Pawn != nullptr)
        {
            const FString Key = WSCoop::PlayerKey(Pawn);
            if (!Key.IsEmpty())
                return Key;
        }
        return WSIdentity::GetSaveName(PC);
    }

    const UItemDefinition FindItem(const FString& TagOrName)
    {
        UItemSubsystem Items = UItemSubsystem::Get();
        if (Items == nullptr)
            return nullptr;
        const FString Wanted = TagOrName.ToLower();
        for (auto Entry : Items.Items)
        {
            if (Entry.Key.ToString().ToLower() == Wanted)
                return Entry.Value;
        }
        for (auto Entry : Items.Items)
        {
            if (Entry.Value != nullptr && Entry.Value.DisplayName.ToString().ToLower() == Wanted)
                return Entry.Value;
        }
        return nullptr;
    }

    void Kick(APlayerController PC, const FString& Reason)
    {
        if (PC == nullptr)
            return;
        const FText Text = FText::FromString(Reason.IsEmpty() ? "Kicked by the server admin." : Reason);
        // Games with the version check (0.0.50+) show the reason on their main menu.
        UWSIdentityComponent Channel = WSIdentity::GetComponent(PC);
        if (Channel != nullptr && !Channel.ReportedModVersion.IsEmpty())
            Channel.WSClientKickReason(Text.ToString());
        PC.ClientWasKicked(Text);
        PC.ClientReturnToMainMenuWithTextReason(Text);
        UWSAdminSubsystem::Get().ScheduleDisconnect(PC);
    }

    // ---- dispatch ----

    // Called by the bootstrap right after `exec` of the command file.
    void ProcessPending()
    {
        const int N = Math::Clamp(Count.GetInt(), 0, MaxCommands);
        for (int i = 0; i < N; i++)
        {
            const FString Line = Read(i).TrimStartAndEnd();
            if (!Line.IsEmpty())
                Dispatch(Line);
        }
        Count.SetInt(0);
    }

    void Dispatch(const FString& Line)
    {
        if (!Line.StartsWith("map"))
            WSDS::Info(f"ADMIN > {Line}");
        TArray<FString> Args = Tokenize(Line);
        if (Args.Num() == 0)
            return;
        const FString Cmd = Args[0].ToLower();
        // Live map lease: renewed every few seconds while someone views the map, so it stays out of the console.
        if (Cmd == "mapwatch")
        {
            UWSMapSubsystem Map = UWSMapSubsystem::Get();
            if (Map != nullptr)
                Map.Watch(Args.Num() >= 2 ? float(String::Conv_StringToDouble(Args[1])) : 15.0);
            return;
        }
        // Developer tools (map survey, test fixtures) only on servers started with -WSDevTools.
        if ((Cmd == "mapsurvey" || Cmd.StartsWith("maptest")) && !System::ParseParam(System::GetCommandLine(), "WSDevTools"))
        {
            Result(false, Cmd, "developer command - start the server with -WSDevTools to use it");
            return;
        }
        if (Cmd == "mapinfo" || Cmd == "mapplayers" || Cmd == "mapprogress" || Cmd == "maptestchunk" || Cmd == "maptestquest" || Cmd == "maptestjson")
        {
            UWSMapSubsystem Map = UWSMapSubsystem::Get();
            if (Map != nullptr)
                Map.Answer(Cmd, Args);
            return;
        }
        UWSAdminSubsystem Admin = UWSAdminSubsystem::Get();

        if (Cmd == "ping")
        {
            Result(true, Cmd, f"pong {JoinFrom(Args, 1)}");
        }
        else if (Cmd == "streamto" && Args.Num() >= 4)
        {
            // Moves the host's own viewpoint so that part of the world streams in (no player needed).
            const FVector Where(String::Conv_StringToDouble(Args[1]), String::Conv_StringToDouble(Args[2]), String::Conv_StringToDouble(Args[3]));
            APlayerController Host = Gameplay::GetPlayerController(0);
            if (Host == nullptr) { Result(false, Cmd, "no host controller"); return; }
            Host.SetActorLocation(Where);
            if (Host.GetControlledPawn() != nullptr)
                Host.GetControlledPawn().SetActorLocation(Where);
            Result(true, Cmd, f"host viewpoint moved to {Where}");
        }
        else if (Cmd == "mapsurvey")
        {
            UWSMapSurveySubsystem Survey = UWSMapSurveySubsystem::Get();
            if (Survey != nullptr)
            {
                // mapsurvey <stepCm> [minX minY maxX maxY]
                TArray<float> Area;
                for (int i = 2; i < Args.Num() && i < 6; i++)
                    Area.Add(float(String::Conv_StringToDouble(Args[i])));
                Survey.Start(Args.Num() >= 2 ? float(String::Conv_StringToDouble(Args[1])) : 30000.0, Area);
            }
        }
        else if (Cmd == "loottest")
        {
            const FString Outcome = WSCoopLoot::SelfTest();
            Result(Outcome.StartsWith("PASS"), Cmd, Outcome);
        }
        else if (Cmd == "viewtest" && Args.Num() >= 3)
        {
            // viewtest node|satchel|chest <playerA> [playerB]   /   viewtest expire <playerA> <seconds>
            const bool bExpire = Args[1] == "expire";
            APlayerController PCB = (!bExpire && Args.Num() >= 4) ? FindController(Args[3]) : nullptr;
            const float Seconds = (bExpire && Args.Num() >= 4) ? float(String::Conv_StringToDouble(Args[3])) : 0.0;
            const FString Outcome = WSCoopLoot::ViewTest(Args[1], FindController(Args[2]), PCB, Seconds);
            Result(!Outcome.StartsWith("FAIL"), Cmd, Outcome);
        }
        else if (Cmd == "bedtest" && Args.Num() >= 2 && System::ParseParam(System::GetCommandLine(), "WSDevTools"))
        {
            // bedtest scan | place|set|status|kill|respawn|destroy <player>
            const FString Outcome = WSBedSpawnTest::Run(Args[1], Args.Num() >= 3 ? FindPlayer(Args[2]) : nullptr);
            Result(!Outcome.StartsWith("FAIL"), Cmd, Outcome);
        }
        else if (Cmd == "lumtest" && Args.Num() >= 3 && System::ParseParam(System::GetCommandLine(), "WSDevTools"))
        {
            const FString Outcome = WSLuminaryRespecTest::Run(Args, FindPlayer(Args[2]));
            Result(!Outcome.StartsWith("FAIL"), Cmd, Outcome);
        }
        else if (Cmd == "markertest" && Args.Num() >= 2 && System::ParseParam(System::GetCommandLine(), "WSDevTools"))
        {
            // markertest list | set <player> [dx dy] | clear <player>
            const FString Outcome = WSMapMarkersTest::Run(Args, Args.Num() >= 3 ? FindPlayer(Args[2]) : nullptr);
            Result(!Outcome.StartsWith("FAIL"), Cmd, Outcome);
        }
        else if (Cmd == "players" || Cmd == "status")
        {
            Admin.EmitState();
            Result(true, Cmd, "state emitted");
        }
        else if (Cmd == "items")
        {
            UItemSubsystem Items = UItemSubsystem::Get();
            int Num = 0;
            for (auto Entry : Items.Items)
            {
                if (Entry.Value == nullptr)
                    continue;
                Log(n"WSDS", f"[WSDS-ITEM] {Entry.Key.ToString()}|{Entry.Value.DisplayName.ToString()}");
                Num++;
            }
            Result(true, Cmd, f"{Num} items");
        }
        else if (Cmd == "kick" && Args.Num() >= 2)
        {
            APlayerController PC = FindController(Args[1]);
            if (PC == nullptr) { Result(false, Cmd, f"no player '{Args[1]}'"); return; }
            const FString Name = PC.PlayerState.GetPlayerName();
            Kick(PC, JoinFrom(Args, 2));
            Event("kick", KeyOf(PC), Name, JoinFrom(Args, 2));
            Result(true, Cmd, f"kicked {Name}");
        }
        else if (Cmd == "ban" && Args.Num() >= 2)
        {
            APlayerController PC = FindController(Args[1]);
            FString Key = Args[1];
            FString Name = Args[1];
            if (PC != nullptr)
            {
                Key = KeyOf(PC);
                Name = PC.PlayerState.GetPlayerName();
            }
            Admin.BannedKeys.Add(Key);
            const FString Reason = JoinFrom(Args, 2);
            if (PC != nullptr)
                Kick(PC, Reason.IsEmpty() ? "You are banned from this server." : f"Banned: {Reason}");
            Event("ban", Key, Name, Reason);
            Result(true, Cmd, f"banned {Name} ({Key})");
        }
        else if (Cmd == "bankey" && Args.Num() >= 2)
        {
            // Sent by the app at startup for each saved ban.
            Admin.BannedKeys.Add(Args[1]);
        }
        else if (Cmd == "unban" && Args.Num() >= 2)
        {
            Admin.BannedKeys.Remove(Args[1]);
            Event("unban", Args[1], "", "");
            Result(true, Cmd, f"unbanned {Args[1]}");
        }
        else if (Cmd == "give" && Args.Num() >= 3)
        {
            APlayerCharacter P = FindPlayer(Args[1]);
            if (P == nullptr) { Result(false, Cmd, f"no spawned player '{Args[1]}'"); return; }
            const UItemDefinition Item = FindItem(Args[2]);
            if (Item == nullptr) { Result(false, Cmd, f"unknown item '{Args[2]}'"); return; }
            const int Amount = Math::Clamp(Args.Num() >= 4 ? String::Conv_StringToInt(Args[3]) : 1, 1, 100000);
            const int Before = P.InventoryComp.GetTotalItemCountByDefinition(Item);
            const int Fits = P.InventoryComp.GetAvailableItemCapacity(Item);
            P.InventoryComp.AddItemsByDefinition(Item, Math::Min(Amount, Math::Max(Fits, 0)), EItemEventFlags::IsWorldPickup);
            const int Given = P.InventoryComp.GetTotalItemCountByDefinition(Item) - Before;
            int Dropped = 0;
            if (Given < Amount)
            {
                // Inventory full: drop the rest at the player's feet.
                UItemStack Rest = UItemStack::CreateItemStack(P, Item, Amount - Given);
                if (Rest != nullptr)
                {
                    P.InventoryComp.DropItemStack(Rest);
                    Dropped = Amount - Given;
                }
            }
            Result(true, Cmd, f"gave {WSCoop::PlayerName(P)} {Given}x {Item.DisplayName.ToString()}" + (Dropped > 0 ? f" (+{Dropped} dropped, inventory full)" : ""));
        }
        else if (Cmd == "xp" && Args.Num() >= 3)
        {
            APlayerCharacter P = FindPlayer(Args[1]);
            if (P == nullptr) { Result(false, Cmd, f"no spawned player '{Args[1]}'"); return; }
            const float Amount = float(String::Conv_StringToDouble(Args[2]));
            P.AbilityComp.RewardExperience(Amount);
            Result(true, Cmd, f"gave {WSCoop::PlayerName(P)} {int(Amount)} XP");
        }
        else if (Cmd == "tp" && Args.Num() >= 3)
        {
            APlayerCharacter P = FindPlayer(Args[1]);
            APlayerCharacter Target = FindPlayer(Args[2]);
            if (P == nullptr || Target == nullptr) { Result(false, Cmd, "both players must be spawned"); return; }
            const FVector Dest = Target.GetActorLocation() + Target.GetActorForwardVector() * -150 + FVector(0, 0, 50);
            const bool bOk = AdminTeleport(P, Dest, Target.GetActorRotation());
            Result(bOk, Cmd, f"teleported {WSCoop::PlayerName(P)} to {WSCoop::PlayerName(Target)}");
        }
        else if (Cmd == "tppos" && Args.Num() >= 5)
        {
            APlayerCharacter P = FindPlayer(Args[1]);
            if (P == nullptr) { Result(false, Cmd, f"no spawned player '{Args[1]}'"); return; }
            const FVector Dest(String::Conv_StringToDouble(Args[2]), String::Conv_StringToDouble(Args[3]), String::Conv_StringToDouble(Args[4]));
            const bool bOk = AdminTeleport(P, Dest, P.GetActorRotation());
            Result(bOk, Cmd, f"teleported {WSCoop::PlayerName(P)} to {int(Dest.X)} {int(Dest.Y)} {int(Dest.Z)}");
        }
        else if (Cmd == "heal" && Args.Num() >= 2)
        {
            APlayerCharacter P = FindPlayer(Args[1]);
            if (P == nullptr) { Result(false, Cmd, f"no spawned player '{Args[1]}'"); return; }
            const float MaxHealth = P.AbilityComp.GetAttributeCurrentValue(UHealthAttributeSet::GetMaxHealthAttribute());
            P.AbilityComp.SetAttributeBaseValue(UHealthAttributeSet::GetHealthAttribute(), MaxHealth);
            Result(true, Cmd, f"healed {WSCoop::PlayerName(P)}");
        }
        else if ((Cmd == "broadcast" || Cmd == "say") && Args.Num() >= 2)
        {
            Admin.Broadcast(JoinFrom(Args, 1));
            Result(true, Cmd, "message sent");
        }
        else if (Cmd == "broadcasttitle" && Args.Num() >= 3)
        {
            Admin.Broadcast(JoinFrom(Args, 2), Args[1]);
            Result(true, Cmd, "message sent");
        }
        else if (Cmd == "motd")
        {
            // WSDS sends line breaks as the two characters backslash + n.
            Admin.Motd = Args.Num() >= 2 ? JoinFrom(Args, 1).Replace("\\n", "\n") : "";
            Result(true, Cmd, Admin.Motd.IsEmpty() ? "message of the day cleared" : "message of the day set");
        }
        else if (Cmd == "whitelist" && Args.Num() >= 2)
        {
            Admin.bWhitelist = Args[1] == "on" || Args[1] == "true" || Args[1] == "1";
            Result(true, Cmd, Admin.bWhitelist ? "whitelist on" : "whitelist off");
        }
        else if (Cmd == "whitelistclear")
        {
            Admin.Whitelist.Empty();
            Result(true, Cmd, "whitelist cleared");
        }
        else if ((Cmd == "whitelistadd" || Cmd == "whitelistremove") && Args.Num() >= 2)
        {
            const FString Entry = JoinFrom(Args, 1).ToLower();
            if (Cmd == "whitelistadd")
                Admin.Whitelist.Add(Entry);
            else
                Admin.Whitelist.Remove(Entry);
            Result(true, Cmd, f"{Admin.Whitelist.Num()} whitelist entries");
        }
        else if (Cmd == "msg" && Args.Num() >= 3)
        {
            APlayerCharacter P = FindPlayer(Args[1]);
            if (P == nullptr) { Result(false, Cmd, f"no spawned player '{Args[1]}'"); return; }
            WSCoop::Notify(P, JoinFrom(Args, 2), "Server Message");
            Result(true, Cmd, f"message sent to {WSCoop::PlayerName(P)}");
        }
        else if (Cmd == "save")
        {
            USaveSubsystem::Get().SaveAll(false);
            Result(true, Cmd, "world and players saved");
        }
        else if (Cmd == "time" && Args.Num() >= 2)
        {
            const float Hour = Math::Clamp(float(String::Conv_StringToDouble(Args[1])), 0.0, 24.0);
            const bool bOk = Admin.SetTimeOfDay(Hour);
            Result(bOk, Cmd, f"time of day set to {Hour}");
        }
        else if (Cmd == "maxplayers" && Args.Num() >= 2)
        {
            Admin.MaxPlayers = Math::Max(1, String::Conv_StringToInt(Args[1]));
            Result(true, Cmd, f"max players {Admin.MaxPlayers}");
        }
        else
        {
            Result(false, Cmd, f"unknown command or missing arguments: {Line}");
        }
    }
}

// Server-side admin state: bans, limits, periodic state reports.
UCLASS()
class UWSAdminSubsystem : UScriptWorldSubsystem
{
    TSet<FString> BannedKeys;
    int MaxPlayers = 0; // 0 = unlimited
    FString Password;

    // Message of the day, shown to every player once they are in the world ("" = none).
    FString Motd;
    // Whitelist: player keys and player names (lower case); only enforced while bWhitelist.
    bool bWhitelist = false;
    TSet<FString> Whitelist;
    private TSet<APlayerController> MotdShown;

    private float StateAccumulator = 0;
    private float Uptime = 0;
    private TArray<APlayerController> PendingDisconnect;
    private TArray<float> PendingDisconnectTimes;
    private TSet<APlayerController> Checked;

    // ---- Lag diagnostics ----
    // While the server is stuck on one long frame, nobody's movement is processed; when it catches up,
    // the players' games snap them back (rubber banding). Every such frame is logged as a HITCH, and a
    // summary is logged every minute while players are online.
    private int64 LastFrameTicks = 0;
    private float PerfWindow = 0;
    private int PerfFrames = 0;
    private float PerfWorst = 0;
    private int PerfHitches = 0;
    private float PerfFrozen = 0;
    private bool bWorldSavedThisFrame = false;
    private int PlayersSavedThisFrame = 0;

    UFUNCTION(BlueprintOverride)
    void OnWorldBeginPlay()
    {
        MaxPlayers = WSDS::IntParam("WSMaxPlayers", 0);
        Password = WSDS::Param("WSPassword", "");

        USaveSubsystem Saves = USaveSubsystem::Get();
        if (Saves != nullptr && System::IsServer() && WSDS::IsHeadlessHost())
        {
            Saves.OnWorldSaved.AddUFunction(this, n"OnWorldSavedForPerf");
            Saves.OnPlayerSaved.AddUFunction(this, n"OnPlayerSavedForPerf");
        }
    }

    UFUNCTION()
    private void OnWorldSavedForPerf(UWorld InWorld, bool bInSuccess)
    {
        bWorldSavedThisFrame = true;
    }

    UFUNCTION()
    private void OnPlayerSavedForPerf(APlayerController InPlayer, bool bInSuccess)
    {
        PlayersSavedThisFrame++;
    }

    private void TrackFrameTime()
    {
        const int64 Now = FDateTime::UtcNow().GetTicks();
        if (LastFrameTicks == 0)
        {
            LastFrameTicks = Now;
            return;
        }
        const float Frame = float(float64(Now - LastFrameTicks) / 10000000.0);
        LastFrameTicks = Now;

        PerfFrames++;
        PerfWindow += Frame;
        PerfWorst = Math::Max(PerfWorst, Frame);
        const float HitchSeconds = Math::Max(0.05, float(WSDS::IntParam("WSHitchMs", 250)) / 1000.0);
        if (Frame >= HitchSeconds)
        {
            PerfHitches++;
            PerfFrozen += Frame;
            FString During;
            if (bWorldSavedThisFrame)
                During += " world save";
            if (PlayersSavedThisFrame > 0)
                During += f" {PlayersSavedThisFrame} player save(s)";
            if (!During.IsEmpty())
                During = f" during:{During}";
            WSDS::Info(f"HITCH: server froze for {Frame:.2}s (players={CountRemotePlayers()}){During}");
        }
        bWorldSavedThisFrame = false;
        PlayersSavedThisFrame = 0;

        if (PerfWindow >= 60.0)
        {
            const int Players = CountRemotePlayers();
            if (Players > 0 || PerfHitches > 0)
            {
                FString Pings;
                AGameStateBase GameState = Gameplay::GetGameState();
                if (GameState != nullptr)
                {
                    for (APlayerState PS : GameState.PlayerArray)
                    {
                        APlayerController PC = PS != nullptr ? Cast<APlayerController>(PS.GetOwner()) : nullptr;
                        if (PC != nullptr && !PC.IsLocalController())
                            Pings += f" {PS.GetPlayerName()}={int(PS.GetPingInMilliseconds())}ms";
                    }
                }
                const float AvgFps = PerfWindow > 0 ? float(PerfFrames) / PerfWindow : 0;
                WSDS::Info(f"PERF last {int(PerfWindow)}s: {AvgFps:.1} fps, worst frame {PerfWorst:.2}s, hitches {PerfHitches} ({PerfFrozen:.1}s frozen), players={Players}, ping:{Pings}");
            }
            PerfWindow = 0;
            PerfFrames = 0;
            PerfWorst = 0;
            PerfHitches = 0;
            PerfFrozen = 0;
        }
    }

    private int CountRemotePlayers() const
    {
        int Count = 0;
        for (int i = 0; i < Gameplay::GetNumPlayerControllers(); i++)
        {
            APlayerController PC = Gameplay::GetPlayerController(i);
            if (PC != nullptr && !PC.IsLocalController())
                Count++;
        }
        return Count;
    }

    UFUNCTION(BlueprintOverride)
    void Tick(float DeltaTime)
    {
        if (!System::IsServer() || !WSDS::IsHeadlessHost())
            return;
        Uptime += DeltaTime;
        TrackFrameTime();

        // Finish kicks: drop the connection if the client has not left on its own.
        for (int i = PendingDisconnect.Num() - 1; i >= 0; i--)
        {
            PendingDisconnectTimes[i] -= DeltaTime;
            if (PendingDisconnectTimes[i] <= 0)
            {
                if (IsValid(PendingDisconnect[i]))
                    PendingDisconnect[i].DestroyActor();
                PendingDisconnect.RemoveAt(i);
                PendingDisconnectTimes.RemoveAt(i);
            }
        }

        StateAccumulator += DeltaTime;
        if (StateAccumulator >= 3.0)
        {
            StateAccumulator = 0;
            EnforceAccessRules();
            EmitState();
        }
    }

    void ScheduleDisconnect(APlayerController PC)
    {
        if (PendingDisconnect.Contains(PC))
            return;
        PendingDisconnect.Add(PC);
        PendingDisconnectTimes.Add(3.0);
    }

    // Bans, password and player limit are checked once a player has reported their identity.
    void EnforceAccessRules()
    {
        int Count = 0;
        AGameStateBase GameState = Gameplay::GetGameState();
        if (GameState == nullptr)
            return;
        for (APlayerState PS : GameState.PlayerArray)
        {
            if (PS == nullptr)
                continue;
            APlayerController PC = PS.GetPlayerController();
            if (PC == nullptr || PC.IsLocalController() || PendingDisconnect.Contains(PC))
                continue;
            Count++;
            if (Checked.Contains(PC))
                continue;

            UWSIdentityComponent Identity = WSIdentity::GetComponent(PC);
            if (Identity == nullptr || !Identity.bReceived)
                continue;
            Checked.Add(PC);

            const FString Key = WSAdmin::KeyOf(PC);
            if (BannedKeys.Contains(Key))
            {
                WSDS::Info(f"ACCESS: '{PS.GetPlayerName()}' ({Key}) is banned - disconnecting");
                WSAdmin::Kick(PC, "You are banned from this server.");
                continue;
            }
            if (!Password.IsEmpty() && Identity.ReportedPassword != Password)
            {
                WSDS::Info(f"ACCESS: '{PS.GetPlayerName()}' gave a wrong server password - disconnecting");
                WSAdmin::Kick(PC, "Wrong server password.");
                continue;
            }
            if (MaxPlayers > 0 && Count > MaxPlayers)
            {
                WSDS::Info(f"ACCESS: server full ({MaxPlayers}) - disconnecting '{PS.GetPlayerName()}'");
                WSAdmin::Kick(PC, "The server is full.");
                continue;
            }
            if (bWhitelist && !Whitelist.Contains(Key.ToLower()) && !Whitelist.Contains(PS.GetPlayerName().ToLower()))
            {
                WSDS::Info(f"ACCESS: '{PS.GetPlayerName()}' ({Key}) is not on the whitelist - disconnecting");
                WSAdmin::Kick(PC, "This server only lets in players on its whitelist.");
                continue;
            }
        }
        ShowMotd();
    }

    // The message of the day, once per connection, as soon as the player is in the world.
    private void ShowMotd()
    {
        if (Motd.IsEmpty())
            return;
        AGameStateBase GameState = Gameplay::GetGameState();
        if (GameState == nullptr)
            return;
        for (APlayerState PS : GameState.PlayerArray)
        {
            APlayerController PC = PS != nullptr ? PS.GetPlayerController() : nullptr;
            if (PC == nullptr || PC.IsLocalController() || MotdShown.Contains(PC) || PendingDisconnect.Contains(PC) || !Checked.Contains(PC))
                continue;
            APlayerCharacter P = Cast<APlayerCharacter>(PS.GetPawn());
            if (P == nullptr)
                continue;
            MotdShown.Add(PC);
            const FString WorldName = WSDS::Param("WSWorldName", "");
            WSCoop::Notify(P, Motd, WorldName.IsEmpty() ? "Welcome" : f"Welcome to {WorldName}");
            WSDS::Info(f"MOTD shown to '{PS.GetPlayerName()}'");
        }
    }

    void EmitState()
    {
        FString PlayersJson;
        AGameStateBase GameState = Gameplay::GetGameState();
        if (GameState != nullptr)
        {
            for (APlayerState PS : GameState.PlayerArray)
            {
                if (PS == nullptr)
                    continue;
                APlayerController PC = PS.GetPlayerController();
                if (PC != nullptr && PC.IsLocalController())
                    continue;
                APlayerCharacter P = Cast<APlayerCharacter>(PS.GetPawn());
                FString Entry = f"{{\"name\":{WSAdmin::Json(PS.GetPlayerName())},\"key\":{WSAdmin::Json(WSAdmin::KeyOf(PC))},\"ping\":{int(PS.GetPingInMilliseconds())}";
                if (P != nullptr)
                {
                    const FVector L = P.GetActorLocation();
                    const int Hp = int(P.AbilityComp.GetAttributeCurrentValue(UHealthAttributeSet::GetHealthAttribute()));
                    const int MaxHp = int(P.AbilityComp.GetAttributeCurrentValue(UHealthAttributeSet::GetMaxHealthAttribute()));
                    Entry += f",\"spawned\":true,\"level\":{int(P.AbilityComp.GetLevel())},\"hp\":{Hp},\"maxhp\":{MaxHp},\"x\":{int(L.X)},\"y\":{int(L.Y)},\"z\":{int(L.Z)}";
                }
                else
                {
                    Entry += ",\"spawned\":false";
                }
                Entry += "}";
                PlayersJson += (PlayersJson.IsEmpty() ? "" : ",") + Entry;
            }
        }
        UWSMapSubsystem Map = UWSMapSubsystem::Get();
        if (Map != nullptr)
            Map.NoteOnlinePlayers();
        const FString Slot = USaveSubsystem::Get().GetSlotName();
        Log(n"WSDS", f"[WSDS-STATE] {{\"uptime\":{int(Uptime)},\"slot\":{WSAdmin::Json(Slot)},\"maxPlayers\":{MaxPlayers},\"players\":[{PlayersJson}]}}");
    }

    // Server-wide announcement. Sent to each player through their own coop channel: the game's
    // broadcast helper also draws on the host's screen, which a headless server does not have.
    void Broadcast(const FString& Message, const FString& Title = "Server Message")
    {
        for (APlayerCharacter P : WSCoop::GetPlayers())
            WSCoop::Notify(P, Message, Title);
    }

    bool SetTimeOfDay(float Hour)
    {
        AHercGameState HercState = Cast<AHercGameState>(Gameplay::GetGameState());
        AWSCoopManager Manager = WSCoop::GetManager();
        UDaySequenceSubsystem DaySequence = UDaySequenceSubsystem::Get();
        ADaySequenceActor Actor = DaySequence != nullptr ? DaySequence.GetDaySequenceActor(false) : nullptr;
        if (HercState == nullptr || Manager == nullptr || Actor == nullptr)
            return false;
        // World time is InitialTimeOfDay + elapsed + a replicated, saved offset (see AHercGameState).
        const float Current = Math::Fmod(HercState.GetInWorldHoursSinceStart(), Actor.DayLength);
        float Delta = Hour - Current;
        if (Delta < 0)
            Delta += Actor.DayLength;
        Manager.SetTimeOffset(Math::Fmod(Manager.TimeOffsetHours + Delta, Actor.DayLength));
        return true;
    }
};
