// WitchspireDedicatedServer - headless host bootstrap.
// Completely inert unless the process was launched with -WSDedicated.
//
// Command line (normally written by the launcher from ServerConfig.json):
//   -WSDedicated                 enable headless host mode
//   -WSSlot=<slot>               EMS save slot to host (created if missing)
//   -WSWorldName=<name>          display / session name
//   -WSLevel=<level>             map to load for a new world (default L_StarterIsland)
//   -WSDifficulty=<0..3>         difficulty for a new world (Easy, Standard, Hard, Impossible)
//   -WSHeartbeat=<seconds>       status log interval (default 60)

namespace WSDS
{
    bool IsHeadlessHost()
    {
        return System::ParseParam(System::GetCommandLine(), "WSDedicated");
    }

    FString Param(const FString& Name, const FString& Default)
    {
        FString Value;
        if (System::ParseParamValue(System::GetCommandLine(), f"{Name}=", Value) && !Value.IsEmpty())
            return Value;
        return Default;
    }

    int IntParam(const FString& Name, int Default)
    {
        const FString Value = Param(Name, "");
        if (Value.IsEmpty())
            return Default;
        return String::Conv_StringToInt(Value);
    }

    void Info(const FString& Message)
    {
        Log(n"WSDS", f"[WSDS] {Message}");
    }

    FString NetModeName(const UObject Context)
    {
        if (System::IsDedicatedServer())
            return "DedicatedServer";
        if (System::IsServer())
            return "Server(Listen/Standalone)";
        return "Client";
    }
}

UCLASS()
class UWSDedicatedBootstrapSubsystem : UScriptWorldSubsystem
{
    private bool bHeadless = false;
    private bool bSessionRequested = false;
    private bool bLoginRequested = false;
    private bool bIsFrontEnd = false;
    private float PollAccumulator = 0;
    private float HeartbeatAccumulator = 0;
    private float LoginWaitSeconds = 0;
    private float UptimeSeconds = 0;
    private int LastLoggedLoginState = -1;

    UFUNCTION(BlueprintOverride)
    void OnWorldBeginPlay()
    {
        bHeadless = WSDS::IsHeadlessHost();
        if (!bHeadless)
            return;

        const FString WorldName = GetWorld().GetName().ToString();
        bIsFrontEnd = WorldName.Contains("FrontEnd");
        const FString Mode = WSDS::NetModeName(this);
        WSDS::Info(f"World begin play: world={WorldName} frontEnd={bIsFrontEnd} netMode={Mode}");
        WSDS::Info(f"Command line: {System::GetCommandLine()}");
    }

    UFUNCTION(BlueprintOverride)
    void Tick(float DeltaTime)
    {
        if (!bHeadless)
            return;

        UptimeSeconds += DeltaTime;

        if (!bIsFrontEnd)
        {
            // A freshly loaded world does not replicate to joining clients until the first save completes
            // (with a player host that happens within seconds; a headless host has no player to load, so
            // clients would sit at "World hasn't begun play" until the first autosave). Prime it once.
            if (!bPrimedAfterLoad)
            {
                PrimeAccumulator += DeltaTime;
                if (PrimeAccumulator >= 5.0)
                {
                    bPrimedAfterLoad = true;
                    WSDS::Info(f"Priming world replication with an initial save (EMS busy={EMS::IsSavingOrLoading()})");
                    SaveNow("startup");
                }
            }

            HeartbeatAccumulator += DeltaTime;
            if (HeartbeatAccumulator >= float(WSDS::IntParam("WSHeartbeat", 60)))
            {
                HeartbeatAccumulator = 0;
                LogHeartbeat();
            }

            ControlAccumulator += DeltaTime;
            if (ControlAccumulator >= 1.0)
            {
                ControlAccumulator = 0;
                TrackPlayers();
                PollControlFiles();
            }
            return;
        }

        if (bSessionRequested)
            return;

        PollAccumulator += DeltaTime;
        if (PollAccumulator < 1.0)
            return;
        PollAccumulator = 0;

        UHercOnlineSubsystem Online = UHercOnlineSubsystem::Get();
        if (Online == nullptr)
        {
            WSDS::Info("Online subsystem not available yet");
            return;
        }

        const EHercLoginState State = Online.GetLoginState();
        if (int(State) != LastLoggedLoginState)
        {
            LastLoggedLoginState = int(State);
            WSDS::Info(f"Login state changed -> {int(State)} (0=NotStarted 1=InProgress 2=LoggedIn 3=Failed)");
        }

        if (State == EHercLoginState::NotStarted && !bLoginRequested)
        {
            WSDS::Info("Requesting online login...");
            bLoginRequested = true;
            Online.Login();
            return;
        }

        if (State == EHercLoginState::InProgress || State == EHercLoginState::NotStarted)
        {
            LoginWaitSeconds += 1.0;
            if (int(LoginWaitSeconds) % 10 == 0)
                WSDS::Info(f"Still waiting for login ({int(LoginWaitSeconds)}s)");
            return;
        }

        if (Online.IsLoggedIn())
            WSDS::Info(f"Online login OK as '{Online.GetLocalPlayerNickname()}' - hosting with EOS session + direct IP");
        else
            WSDS::Info("No Steam/EOS account on this host (expected for a headless server) - hosting in DIRECT-IP mode");
        HostWorld();
    }

    private void HostWorld()
    {
        bSessionRequested = true;

        USaveSubsystem SaveSubsystem = USaveSubsystem::Get();
        const FString Slot = WSDS::Param("WSSlot", "WSDedicatedWorld");
        const FString WorldName = WSDS::Param("WSWorldName", "Witchspire Dedicated");
        const FString Level = WSDS::Param("WSLevel", "L_StarterIsland");

        TArray<FString> ExistingSlots = SaveSubsystem.GetSaveSlots();
        WSDS::Info(f"Known save slots: {ExistingSlots.Num()}");
        for (const FString& Existing : ExistingSlots)
            WSDS::Info(f"  slot: {Existing}");

        const bool bExisting = ExistingSlots.Contains(Slot);
        SaveSubsystem.SetSlotName(Slot, WorldName);

        USaveGameSlot SlotInfo = SaveSubsystem.GetCurrentSaveGameSlot();
        FString LevelToLoad = Level;
        if (SlotInfo == nullptr)
        {
            WSDS::Info("WARNING: no slot info object after SetSlotName; using configured level");
        }
        else
        {
            if (bExisting && SlotInfo.Level.IsNone())
            {
                SlotInfo.SlotInfo.Level = FName(Level);
                WSDS::Info(f"Existing world had no level recorded; using {Level}");
            }
            else if (!bExisting)
            {
                const int Difficulty = Math::Clamp(WSDS::IntParam("WSDifficulty", 1), 0, 3);
                SlotInfo.SlotInfo.Level = FName(Level);
                SlotInfo.Difficulty = EGameDifficulty(Difficulty);
                SlotInfo.DifficultySettings.Empty();
                WSDS::Info(f"New world: level={Level} difficulty={Difficulty}");
            }
            LevelToLoad = SlotInfo.Level.ToString();
        }

        const int TickRate = Math::Clamp(WSDS::IntParam("WSTickRate", 30), 10, 120);
        System::ExecuteConsoleCommand(f"t.MaxFPS {TickRate}");
        WSDS::Info(f"Server tick rate capped at {TickRate} Hz");

        const int AutoSave = WSDS::IntParam("WSAutoSave", 300);
        System::ExecuteConsoleCommand(f"Herc.SaveGame.AutoSaveTimer {AutoSave}");
        WSDS::Info(f"Autosave interval set to {AutoSave}s");

        WSDS::Info(f"Hosting slot='{Slot}' existing={bExisting} world='{WorldName}' level='{LevelToLoad}'");
        UHercOnlineSubsystem Online = UHercOnlineSubsystem::Get();
        if (Online != nullptr && Online.IsLoggedIn())
        {
            // Logged-in host: normal path (listen server + EOS/Steam lobby advertisement).
            Online.CreateSession(LevelToLoad, WorldName);
            WSDS::Info("CreateSession issued (listed in the in-game server browser + direct IP)");
        }
        else
        {
            // No online identity: a lobby cannot be advertised, so skip CreateSession (it would only
            // log 'HostingPlayerNum ... does not have online identity') and open the map as a listen server.
            WSDS::Info("Opening world as listen server - DIRECT-IP only (not listed in the in-game browser)");
            Gameplay::OpenLevel(FName(LevelToLoad), true, "listen");
        }
    }

    // ---- Server operations (game world only) ----

    private float ControlAccumulator = 0;
    private float PrimeAccumulator = 0;
    private bool bPrimedAfterLoad = false;
    private TMap<APlayerState, FString> KnownPlayers;
    private bool bSaveRequestHandled = false;
    private bool bShutdownStarted = false;
    private bool bCommandsHandled = false;

    // Players that are real remote clients (excludes the headless host's own local controller).
    TArray<APlayerState> GetRemotePlayers() const
    {
        TArray<APlayerState> Result;
        AGameStateBase GameState = Gameplay::GetGameState();
        if (GameState == nullptr)
            return Result;
        for (APlayerState PS : GameState.PlayerArray)
        {
            if (PS == nullptr)
                continue;
            APlayerController PC = PS.GetPlayerController();
            if (PC != nullptr && PC.IsLocalController())
                continue;
            Result.Add(PS);
        }
        return Result;
    }

    private void TrackPlayers()
    {
        TArray<APlayerState> Current = GetRemotePlayers();

        for (APlayerState PS : Current)
        {
            if (!KnownPlayers.Contains(PS))
            {
                const FString Id = PS.GetUniqueId().ToString();
                KnownPlayers.Add(PS, f"{PS.GetPlayerName()} ({Id})");
                WSDS::Info(f"PLAYER JOINED: {PS.GetPlayerName()} id={Id} players={Current.Num()}");
            }
        }

        TArray<APlayerState> Departed;
        for (auto Entry : KnownPlayers)
        {
            if (!IsValid(Entry.Key) || !Current.Contains(Entry.Key))
                Departed.Add(Entry.Key);
        }

        for (APlayerState PS : Departed)
        {
            FString Label;
            KnownPlayers.Find(PS, Label);
            KnownPlayers.Remove(PS);
            WSDS::Info(f"PLAYER LEFT: {Label} players={Current.Num()} - saving world");
            SaveNow("player-left");
        }
    }

    FString ControlDir() const
    {
        return f"{Paths::ProjectSavedDir()}WSDS/";
    }

    private void PollControlFiles()
    {
        const FString Dir = ControlDir();
        if (Paths::FileExists(f"{Dir}save.request"))
        {
            if (!bSaveRequestHandled)
            {
                bSaveRequestHandled = true;
                WSDS::Info("Control: save requested by launcher");
                SaveNow("launcher-request");
            }
        }
        else
        {
            bSaveRequestHandled = false;
        }

        // Admin commands from the WSDS app: exec the command file once per commands.ready marker.
        if (Paths::FileExists(f"{Dir}commands.ready"))
        {
            if (!bCommandsHandled)
            {
                bCommandsHandled = true;
                // UE's `exec` resolves file names relative to <Project>/Binaries.
                const FString CommandFile = Paths::ConvertRelativePathToFull(f"{Dir}commands.txt");
                const FString BinariesDir = Paths::ConvertRelativePathToFull(f"{Paths::ProjectDir()}Binaries/");
                FString Relative;
                if (!Paths::MakePathRelativeTo(CommandFile, BinariesDir, Relative))
                    Relative = CommandFile;
                System::ExecuteConsoleCommand(f"exec \"{Relative}\"");
                WSAdmin::ProcessPending();
            }
        }
        else
        {
            bCommandsHandled = false;
        }

        if (!bShutdownStarted && Paths::FileExists(f"{Dir}shutdown.request"))
        {
            bShutdownStarted = true;
            WSDS::Info("Control: graceful shutdown requested - saving all players and world");
            SaveNow("shutdown");
            WSDS::Info("SHUTDOWN: save finished, exiting process");
            System::ExecuteConsoleCommand("quit");
        }
    }

    void SaveNow(const FString& Reason)
    {
        USaveSubsystem SaveSubsystem = USaveSubsystem::Get();
        if (SaveSubsystem == nullptr || !SaveSubsystem.IsEnabled())
        {
            WSDS::Info(f"SAVE SKIPPED ({Reason}): save system not enabled");
            return;
        }
        SaveSubsystem.SaveAll(false);
        WSDS::Info(f"SAVE COMPLETE ({Reason}) slot='{SaveSubsystem.GetSlotName()}'");
    }

    private void LogHeartbeat()
    {
        TArray<APlayerState> Remote = GetRemotePlayers();
        const int Players = Remote.Num();
        FString Names;
        for (APlayerState PS : Remote)
        {
            const bool bHasPawn = PS.GetPawn() != nullptr;
            Names += f"{PS.GetPlayerName()}(pawn={bHasPawn}) ";
        }
        const FString Mode = WSDS::NetModeName(this);
        WSDS::Info(f"Heartbeat emsBusy={EMS::IsSavingOrLoading()} uptime={int(UptimeSeconds)}s world={GetWorld().GetName()} netMode={Mode} players={Players} [{Names}] slot='{USaveSubsystem::Get().GetSlotName()}'");
    }
};
